module PostgRest
    exposing
        ( Schema
        , Query
        , Field
        , OrderBy
        , Filter
        , Settings
        , defaultSettings
        , schema
        , field
        , query
        , subQuery
        , select
        , order
        , filter
        , like
        , eq
        , gte
        , gt
        , lte
        , lt
        , ilike
        , in'
        , is
        , not'
        , asc
        , desc
        , postgRest
        )

{-| PostgREST Query Builder
@docs Schema, Query, Field, OrderBy, Filter, Settings, defaultSettings, schema, field, query, subQuery, select, order, filter, like, eq, gte, gt, lte, lt, ilike, in', is, not', asc, desc, postgRest
-}

import Dict
import Http
import Json.Decode as Decode
import String
import Task


{-| -}
type Schema s
    = Schema String s


unwrapSchema : Schema s -> ( String, s )
unwrapSchema schema =
    case schema of
        Schema name shape ->
            ( name, shape )


{-| -}
type Query s
    = Query String s QueryParams


unwrapQuery : Query s -> ( String, s, QueryParams )
unwrapQuery query =
    case query of
        Query name shape params ->
            ( name, shape, params )


type alias QueryParams =
    { select : List Field
    , order : List OrderBy
    , filter : List Filter
    }


{-| -}
type Field
    = Simple String
    | Nested String QueryParams


{-| -}
type OrderBy
    = Asc Field
    | Desc Field


{-| -}
type Condition
    = Like String
    | ILike String
    | Eq String
    | Gte String
    | Gt String
    | Lte String
    | Lt String
    | In (List String)
    | Is String


{-| -}
type Filter
    = Filter Bool Condition Field


{-| -}
type alias Settings =
    { count : Bool
    , singular : Bool
    , limit : Maybe Int
    , offset : Maybe Int
    }


{-| -}
defaultSettings : Settings
defaultSettings =
    { count = False
    , singular = False
    , limit = Nothing
    , offset = Nothing
    }


{-| thanks lukewestby
https://github.com/elm-lang/core/issues/657
-}
coerceToString : a -> String
coerceToString value =
    let
        stringValue =
            toString value
    in
        stringValue
            |> Decode.decodeString Decode.string
            |> Result.withDefault stringValue


{-| -}
schema : String -> s -> Schema s
schema =
    Schema


{-| -}
field : String -> Field
field =
    Simple


{-| -}
query : Schema s -> Query s
query schema =
    let
        ( name, shape ) =
            unwrapSchema schema
    in
        Query name
            shape
            { select = []
            , filter = []
            , order = []
            }


{-| -}
subQuery : Query s -> a -> Field
subQuery query =
    let
        ( name, _, params ) =
            unwrapQuery query
    in
        always <| Nested name params


{-| -}
select : List (s -> Field) -> Query s -> Query s
select selects query =
    let
        -- addSelects : s -> QueryParams -> QueryParams
        -- https://github.com/elm-lang/elm-compiler/issues/1214
        addSelects shape params =
            { params
                | select = params.select ++ List.map (\fn -> fn shape) selects
            }
    in
        mapQueryParams addSelects query


{-| -}
order : List (s -> OrderBy) -> Query s -> Query s
order orders query =
    let
        -- addOrders : s -> QueryParams -> QueryParams
        addOrders shape params =
            { params
                | order = params.order ++ List.map (\fn -> fn shape) orders
            }
    in
        mapQueryParams addOrders query


{-| -}
filter : List (s -> Filter) -> Query s -> Query s
filter filters query =
    let
        -- addFilters : s -> QueryParams -> QueryParams
        addFilters shape params =
            { params
                | filter = params.filter ++ List.map (\fn -> fn shape) filters
            }
    in
        mapQueryParams addFilters query


mapQueryParams : (s -> QueryParams -> QueryParams) -> Query s -> Query s
mapQueryParams fn query =
    let
        ( name, shape, params ) =
            unwrapQuery query
    in
        Query name shape (fn shape params)


singleValueFilterFn :
    (String -> Condition)
    -> a
    -> (s -> Field)
    -> (s -> Filter)
singleValueFilterFn condCtor condArg fieldAccessor =
    let
        -- shapeToFilter : s -> Filter
        shapeToFilter shape =
            Filter False
                (condCtor (coerceToString condArg))
                (fieldAccessor shape)
    in
        shapeToFilter


{-| -}
like : String -> (s -> Field) -> (s -> Filter)
like =
    singleValueFilterFn Like


{-| -}
eq : a -> (s -> Field) -> (s -> Filter)
eq =
    singleValueFilterFn Eq


{-| -}
gte : a -> (s -> Field) -> (s -> Filter)
gte =
    singleValueFilterFn Gte


{-| -}
gt : a -> (s -> Field) -> (s -> Filter)
gt =
    singleValueFilterFn Gt


{-| -}
lte : a -> (s -> Field) -> (s -> Filter)
lte =
    singleValueFilterFn Lte


{-| -}
lt : a -> (s -> Field) -> (s -> Filter)
lt =
    singleValueFilterFn Lt


{-| -}
ilike : String -> (s -> Field) -> (s -> Filter)
ilike =
    singleValueFilterFn ILike


{-| -}
in' : List a -> (s -> Field) -> (s -> Filter)
in' condArgs fieldAccessor =
    let
        shapeToFilter shape =
            Filter False
                (In (List.map coerceToString condArgs))
                (fieldAccessor shape)
    in
        shapeToFilter


{-| -}
is : a -> (s -> Field) -> (s -> Filter)
is =
    singleValueFilterFn Is


{-| -}
not' :
    (a -> (s -> Field) -> (s -> Filter))
    -> a
    -> (s -> Field)
    -> (s -> Filter)
not' filterAccessorCtor val fieldAccessor =
    let
        filterAccessor =
            filterAccessorCtor val fieldAccessor

        shapeToNegatedFilter shape =
            case filterAccessor shape of
                Filter negated cond field ->
                    Filter (not negated) cond field
    in
        shapeToNegatedFilter


{-| -}
asc : (s -> Field) -> (s -> OrderBy)
asc fieldAccessor =
    (\shape -> Asc (fieldAccessor shape))


{-| -}
desc : (s -> Field) -> (s -> OrderBy)
desc fieldAccessor =
    (\shape -> Desc (fieldAccessor shape))


{-| -}
postgRest : String -> Settings -> Query s -> Http.Request
postgRest url settings query =
    let
        { count, singular, limit, offset } =
            settings

        ( name, _, params ) =
            unwrapQuery query

        trailingSlashUrl =
            if String.right 1 url == "/" then
                url
            else
                url ++ "/"

        queryUrl =
            [ fieldsToKeyValue params.select
            , params
                |> labelOrders ""
                |> labeledOrdersToKeyValue
            , params
                |> labelFilters ""
                |> labeledFiltersToKeyValues
            , offsetToKeyValue offset
            , limitToKeyValues limit
            ]
                |> List.foldl (++) []
                |> Http.url (trailingSlashUrl ++ name)

        pluralityHeader =
            if singular then
                [ ( "Prefer", "plurality=singular" ) ]
            else
                []

        countHeader =
            if not count then
                [ ( "Prefer", "count=none" ) ]
            else
                []

        headers =
            pluralityHeader ++ countHeader
    in
        { verb = "GET"
        , headers = headers
        , url = queryUrl
        , body = Http.empty
        }


fieldsToKeyValue : List Field -> List ( String, String )
fieldsToKeyValue fields =
    let
        fieldToString : Field -> String
        fieldToString field =
            case field of
                Simple name ->
                    name

                Nested name { select } ->
                    name ++ "{" ++ fieldsToString select ++ "}"

        fieldsToString : List Field -> String
        fieldsToString fields =
            case fields of
                [] ->
                    "*"

                _ ->
                    fields
                        |> List.map fieldToString
                        |> String.join ","
    in
        case fields of
            [] ->
                []

            _ ->
                [ ( "select", fieldsToString fields ) ]


labelFilters : String -> QueryParams -> List ( String, Filter )
labelFilters prefix params =
    let
        labelWithPrefix =
            (,) prefix

        labeledFilters =
            List.map labelWithPrefix params.filter

        labelNestedFilters field =
            case field of
                Simple _ ->
                    Nothing

                Nested nestedName nestedParams ->
                    Just (labelFilters (prefix ++ nestedName ++ ".") nestedParams)

        labeledNestedFilters =
            params.select
                |> List.filterMap labelNestedFilters
                |> List.concat
    in
        labeledFilters ++ labeledNestedFilters


labeledFiltersToKeyValues : List ( String, Filter ) -> List ( String, String )
labeledFiltersToKeyValues filters =
    let
        contToString : Condition -> String
        contToString cond =
            case cond of
                Like str ->
                    "like." ++ str

                Eq str ->
                    "eq." ++ str

                Gte str ->
                    "gte." ++ str

                Gt str ->
                    "gt." ++ str

                Lte str ->
                    "lte." ++ str

                Lt str ->
                    "lt." ++ str

                ILike str ->
                    "ilike." ++ str

                In list ->
                    "in." ++ String.join "," list

                Is str ->
                    "is." ++ str

        filterToKeyValue : ( String, Filter ) -> Maybe ( String, String )
        filterToKeyValue ( prefix, filter ) =
            case filter of
                Filter True cond (Simple key) ->
                    Just ( prefix ++ key, "not." ++ contToString cond )

                Filter False cond (Simple key) ->
                    Just ( prefix ++ key, contToString cond )

                Filter _ _ (Nested _ _) ->
                    Nothing
    in
        List.filterMap filterToKeyValue filters


labelOrders : String -> QueryParams -> List ( String, OrderBy )
labelOrders prefix params =
    let
        labelWithPrefix =
            (,) prefix

        labeledOrders =
            List.map labelWithPrefix params.order

        labelNestedOrders field =
            case field of
                Simple _ ->
                    Nothing

                Nested nestedName nestedParams ->
                    Just (labelOrders (prefix ++ nestedName ++ ".") nestedParams)

        labeledNestedOrders =
            params.select
                |> List.filterMap labelNestedOrders
                |> List.concat
    in
        labeledOrders ++ labeledNestedOrders


labeledOrdersToKeyValue : List ( String, OrderBy ) -> List ( String, String )
labeledOrdersToKeyValue orders =
    let
        labeledOrderToKeyValue : ( String, List OrderBy ) -> Maybe ( String, String )
        labeledOrderToKeyValue ( prefix, orders ) =
            case orders of
                [] ->
                    Nothing

                _ ->
                    Just
                        ( prefix ++ "order"
                        , orders
                            |> List.filterMap orderToString
                            |> String.join ","
                        )

        orderToString : OrderBy -> Maybe String
        orderToString order =
            case order of
                Asc (Simple name) ->
                    Just (name ++ ".asc")

                Desc (Simple name) ->
                    Just (name ++ ".desc")

                _ ->
                    Nothing
    in
        orders
            |> List.foldr
                (\( prefix, order ) dict ->
                    Dict.update prefix
                        (\m ->
                            case m of
                                Nothing ->
                                    Just [ order ]

                                Just os ->
                                    Just (order :: os)
                        )
                        dict
                )
                Dict.empty
            |> Dict.toList
            |> List.filterMap labeledOrderToKeyValue


offsetToKeyValue : Maybe Int -> List ( String, String )
offsetToKeyValue maybeOffset =
    case maybeOffset of
        Nothing ->
            []

        Just offset ->
            [ ( "offset", toString offset ) ]


limitToKeyValues : Maybe Int -> List ( String, String )
limitToKeyValues maybeLimit =
    case maybeLimit of
        Nothing ->
            []

        Just limit ->
            [ ( "limit", toString limit ) ]