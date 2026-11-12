---
name: notion
description: Search, read, and write the team's Notion workspace (pages, wikis, meeting notes, databases and trackers) through the Notion API with your own Notion connection. Use whenever someone mentions Notion, shares a notion.so or notion.site link, or asks about content that lives in Notion, including creating or updating pages and database rows.
metadata:
  source: https://github.com/Agent-Deployment-Co/bishop-cookbook
---

# Notion

You reach Notion through its REST API as your own internal connection. Make every call through `notion.sh`, beside this file. It adds the token from `NOTION_TOKEN`, pins the API version (`2026-03-11`), and retries rate limits:

```sh
bash <this skill's directory>/notion.sh METHOD PATH [BODY | -]
```

`PATH` is relative to `https://api.notion.com/v1/`. `BODY` is JSON, or `-` to read it from stdin (use a quoted heredoc for anything multi-line). The script prints the response JSON. On an HTTP error it still prints the error JSON and exits 1. Exit 2 means `NOTION_TOKEN` isn't set: tell the person Notion isn't connected here yet. Never ask anyone to paste a token into chat.

The examples below write `notion.sh` for short.

The people you talk to don't need to know how you reach Notion. Never mention this skill by name, describe using a skill, or mention the script, the API, or tokens when you talk about Notion. Say what you found or changed and link to it, the way a colleague would.

## What you can see

The connection only sees pages and databases someone has shared with it in Notion. Pages nested under a shared page inherit access. A `404 object_not_found` on something a person can see almost always means it isn't shared with the connection. Say so, and ask them to add the connection from that page's `•••` menu under **Connections**. Don't report the page as missing.

What the connection may do (read, update, insert, comments) is set in Notion. A `403 restricted_resource` means it lacks that capability. Tell the person rather than working around it.

## Rules for writing

- Read whenever it helps answer. Write only when someone asks you to.
- Prefer targeted edits (`update_content`) and appends. Before `replace_content` on a page that already has content, read the page and confirm with the person, because it rewrites the whole page.
- Never set `allow_deleting_content`, trash a page, or change a database's schema unless the person explicitly asked for that specific change.
- After any write, give the page's link. Page objects carry a `url`. Otherwise use `https://www.notion.so/<id without hyphens>`.

## IDs from links

A Notion link ends in a 32-character hex ID: in `https://www.notion.so/acme/Team-Wiki-1a2b...9f`, the ID is the last 32 hex characters. The API accepts it with or without hyphens. In a link with `?v=`, the path ID is the database and `v` is a view. A `p=` parameter is a page opened from that database.

## Search

Search matches titles only, not body text:

```sh
notion.sh POST search '{"query": "onboarding", "page_size": 10}' \
  | jq -r '.results[] | [.object, .id, ([.title[]?, (.properties[]? | select(.type == "title") | .title[]?)] | map(.plain_text) | join("")), .url] | @tsv'
```

To return only pages, add `"filter": {"property": "object", "value": "page"}`. For only databases, use `"value": "data_source"`. When `has_more` is true, repeat the call with `"start_cursor": "<next_cursor>"`. This applies to every list endpoint.

## Read a page

```sh
notion.sh GET 'pages/<page_id>/markdown?markdown_version=v2' | jq -r .markdown
```

If the response has `"truncated": true`, fetch each ID in `unknown_block_ids` the same way. A 404 on those means a nested page isn't shared. Read properties (title, status, dates, people) with `notion.sh GET pages/<page_id>`.

## Databases

A database holds one or more data sources, and you query the data source. Get the data source ID from the database, then check its schema so filters and new rows use the right property names and types:

```sh
notion.sh GET databases/<database_id> | jq '.data_sources'
notion.sh GET data_sources/<data_source_id> | jq '.properties | map_values(.type)'
notion.sh POST data_sources/<data_source_id>/query - <<'EOF'
{"page_size": 25,
 "filter": {"and": [
   {"property": "Status", "status": {"equals": "In progress"}},
   {"property": "Due", "date": {"on_or_before": "2026-11-30"}}]},
 "sorts": [{"property": "Due", "direction": "ascending"}]}
EOF
```

The filter key matches the property type: `status`, `select`, `multi_select`, `date`, `checkbox`, `people`, `number`, `title`, or `rich_text`. For example, `{"property": "Done", "checkbox": {"equals": true}}` or `{"property": "Name", "title": {"contains": "Acme"}}`. See [filters](https://developers.notion.com/reference/filter-data-source-entries) for the full list.

## Create a page

Under a page, the only property is `title`. Write the body as [Notion-flavored Markdown](https://developers.notion.com/guides/data-apis/notion-flavored-markdown):

```sh
notion.sh POST pages - <<'EOF'
{"parent": {"type": "page_id", "page_id": "<page_id>"},
 "properties": {"title": {"title": [{"text": {"content": "Weekly notes"}}]}},
 "markdown": "## Agenda\n\n- First item",
 "markdown_version": "v2"}
EOF
```

To add a row to a database, set the parent to `{"type": "data_source_id", "data_source_id": "<id>"}`. Key `properties` by the schema's names, with each value shaped by its type:

| Type | Value |
| --- | --- |
| title, rich_text | `{"title": [{"text": {"content": "…"}}]}` (or `rich_text`) |
| status, select | `{"status": {"name": "Done"}}` (or `select`) |
| multi_select | `{"multi_select": [{"name": "A"}, {"name": "B"}]}` |
| date | `{"date": {"start": "2026-11-05"}}` |
| number, checkbox, url | `{"number": 3}`, `{"checkbox": true}`, `{"url": "https://…"}` |
| people, relation | `{"people": [{"id": "<user_id>"}]}`, `{"relation": [{"id": "<page_id>"}]}` |

## Edit a page

Change properties with `PATCH pages/<page_id>`, using the same value shapes:

```sh
notion.sh PATCH pages/<page_id> '{"properties": {"Status": {"status": {"name": "Done"}}}}'
```

Edit content with search-and-replace. Each `old_str` must match the page's v2 markdown exactly, so read the page first and copy from it:

```sh
notion.sh PATCH pages/<page_id>/markdown - <<'EOF'
{"type": "update_content", "markdown_version": "v2",
 "update_content": {"content_updates": [
   {"old_str": "Owner: TBD", "new_str": "Owner: Dana"}]}}
EOF
```

To append, use `{"type": "insert_content", "markdown_version": "v2", "insert_content": {"content": "…", "position": {"type": "end"}}}`. Use `"position": {"type": "start"}` to prepend. A response with a `warnings` array means part of the edit didn't apply, for example an `old_str` that matched nothing. Check it, and tell the person anything that didn't land.

## Errors

| Status / code | Meaning |
| --- | --- |
| 401 `unauthorized` | The token is wrong or revoked. Tell the person Notion's connection needs a new token. |
| 403 `restricted_resource` | The connection lacks the capability (for example, update content). |
| 404 `object_not_found` | The item isn't shared with the connection, or doesn't exist. |
| 400 `validation_error` | The body is wrong. The `message` says what to fix. |
| 429 `rate_limited` | The script already waited and retried. If it still fails, slow down and batch less. |

The limit is about 3 requests a second. Don't loop over hundreds of pages without being asked.
