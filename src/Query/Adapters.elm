module Query.Adapters exposing (postgRest)

{-| Query.Adapters
# Adapters
@docs postgRest
-}

import Query.Types exposing (..)
import Http
import String


{-| -}
postgRest : Query shape -> Http.Request
postgRest query =
    let
        { url, fields, filters, orders, limit, offset, singular, suppressCount, verb, schema } =
            unwrapQuery query

        ( schemaName, _ ) =
            unwrapSchema schema

        trailingSlashUrl =
            if String.right 1 url == "/" then
                url
            else
                url ++ "/"

        queryUrl =
            [ ordersToKeyValue orders
            , fieldsToKeyValue fields
            , filtersToKeyValues filters
            , offsetToKeyValue offset
            , limitToKeyValues limit
            ]
                |> List.foldl (++) []
                |> Http.url (trailingSlashUrl ++ schemaName)

        pluralityHeader =
            if singular then
                [ ( "Prefer", "plurality=singular" ) ]
            else
                []

        countHeader =
            if suppressCount then
                [ ( "Prefer", "count=none" ) ]
            else
                []

        headers =
            pluralityHeader ++ countHeader
    in
        { verb = verb
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
                SimpleField name ->
                    name

                NestedField name nestedFields ->
                    name ++ "{" ++ fieldsToString nestedFields ++ "}"

        fieldsToString : List Field -> String
        fieldsToString fields =
            case fields of
                [] ->
                    "*"

                _ ->
                    fields
                        |> List.map fieldToString
                        |> join ","
    in
        case fields of
            [] ->
                []

            _ ->
                [ ( "select", fieldsToString fields ) ]


filtersToKeyValues : List Filter -> List ( String, String )
filtersToKeyValues filters =
    let
        -- `Maybe` b/c we should not be able to filter on a NestedField
        condToKeyValue : Condition -> Maybe ( String, String )
        condToKeyValue cond =
            case cond of
                Like (SimpleField name) str ->
                    Just ( name, "like." ++ str )

                Eq (SimpleField name) str ->
                    Just ( name, "eq." ++ str )

                Gte (SimpleField name) str ->
                    Just ( name, "gte." ++ str )

                Gt (SimpleField name) str ->
                    Just ( name, "gt." ++ str )

                Lte (SimpleField name) str ->
                    Just ( name, "lte." ++ str )

                Lt (SimpleField name) str ->
                    Just ( name, "lt." ++ str )

                ILike (SimpleField name) str ->
                    Just ( name, "ilike." ++ str )

                In (SimpleField name) list ->
                    Just ( name, "in." ++ join "," list )

                Is (SimpleField name) str ->
                    Just ( name, "is." ++ str )

                Contains (SimpleField name) str ->
                    Just ( name, "@@." ++ str )

                _ ->
                    Nothing

        filterToKeyValue : Filter -> Maybe ( String, String )
        filterToKeyValue filter =
            case filter of
                Filter negated cond ->
                    if negated then
                        Maybe.map (\( key, value ) -> ( key, "not." ++ value ))
                            (condToKeyValue cond)
                    else
                        (condToKeyValue cond)
    in
        List.filterMap filterToKeyValue filters


ordersToKeyValue : List OrderBy -> List ( String, String )
ordersToKeyValue orders =
    let
        -- `Maybe` b/c we should not be able to filter on a NestedField
        orderToString : OrderBy -> Maybe String
        orderToString order =
            case order of
                Ascending (SimpleField name) ->
                    Just (name ++ ".asc")

                Descending (SimpleField name) ->
                    Just (name ++ ".desc")

                _ ->
                    Nothing

        ordersToString : List OrderBy -> String
        ordersToString order =
            orders
                |> List.filterMap orderToString
                |> join ","
    in
        case orders of
            [] ->
                []

            _ ->
                [ ( "order", ordersToString orders ) ]


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



-- General Helpers


join : String -> List String -> String
join separator strings =
    strings
        |> List.indexedMap (,)
        |> List.foldl
            (\( i, next ) total ->
                total
                    ++ next
                    ++ if i /= (List.length strings) - 1 then
                        separator
                       else
                        ""
            )
            ""