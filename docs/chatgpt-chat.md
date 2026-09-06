# ChatGPT Chat allowances

ChatGPT Chat appears above ChatGPT Agentic under OpenAI. It tracks Image
Generation and Deep Research, and — when asked to — the GPT-6 Pro and
GPT-5.6 Sol Pro message allowances. Enable it in OpenAI settings; a Codex
login is enough, and the existing browser import or built-in login works
too. No browser extension is required.

## Learning totals

The adapter reads the service remainder and reset time. It tries the Codex
CLI's OAuth bearer first — the credential the Codex quota already reads — and
only then the web cookie and the WebView session, so a Codex login needs no
separate web login for Chat. It reuses Agentic's `/wham/usage` plan parser
through whichever Chat transport answered. There are no fixed feature totals
and no cloud-history or model-message collector.

A first observation is not a reset. Three independent reset observations with
the same remainder establish a learned total. Reads must bracket the reported
boundary and be close enough to it to avoid treating a long offline gap as a
fresh full allowance. Moving unused reset times do not count. A changed total,
account or plan starts learning again. A failed plan read withholds confidence.

While learning, every feature has an indeterminate bar and an estimated
remaining count. Once the total and window are learned, the source returns a normal percentage
bucket. The existing primary-provider quota row, forecast bar, pace, history,
menu bar, and mini-window paths handle it without a separate Chat presentation.
Learning state uses the same bar height and track, with indeterminate fill.

## Pro model messages

The service reports no count for GPT-6 Pro or GPT-5.6 Sol Pro. Its
`conversation/init` reply names a model only once it is exhausted
(`model_limits`: `model_slug`, `resets_after`, `using_default_model_slug`),
and `/backend-api/models` carries no allowance fields. What OpenAI publishes
is the total per plan, in "GPT-5.6 and GPT-6 Pro in ChatGPT" (help article
20001354, read 2026-09-07):

| Plan | GPT-6 Pro | GPT-5.6 Sol Pro |
| --- | --- | --- |
| Pro $200 (`pro`) | 200 messages per week | 170 per day; both models together 200 per day |
| Pro $100 (`prolite`) | one shared allowance of 50 messages per week | |

"Sync saved Chat history across devices" in OpenAI settings turns the count
on. It is off by default. The reader lists the account's saved conversations
newest first, stops at the first one not updated inside the last week, skips
Work rows (`conversation_origin` `tpp` or `flora`) and temporary chats, and
fetches only conversations whose revision changed, at most 24 per refresh
and within 25 seconds. Each user turn is charged to the model of its final
answer, once, however often it was regenerated. Only hashed ids, times and
model slugs are cached, under `~/.vibebar/chatgpt_chat_history.json`.

The service states no window start, so each bucket is the count inside a
trailing window ending now, against the published total, marked estimated.
While part of the window is unread — the budget ran out, a fetch failed, or
the list was cut short — the row shows the count and "history sync is
incomplete" instead of a percentage. A throttled model overrides the count
with the service's own exhausted state and reset time; a shared allowance
is treated as exhausted only when every model it covers is.

Plans other than `pro` and `prolite` get no Pro buckets, because the table
above does not cover them. Temporary chats, deleted conversations and turns
whose answer never finished are not counted; the settings pane reports the
excluded Work conversations and unclassified turns.

## Subscription labels

Settings > System > Subscription name format controls plan labels across
providers. The five formats show the product and tier with or without the
multiplier, the tier alone, or the multiplier alone. For example: ChatGPT Pro
20x, ChatGPT Pro, Pro, Pro 20x, and 20x. A plan without a multiplier keeps its
tier name in the last format; custom labels take precedence. This is a display
choice and never changes the account or plan used by quota learning.

## Reset records

Reset history retains the before/after usage, previous and new deadlines, and
the observation interval. Scheduled resets have no extra marker. Semantic icons identify early resets
with a new deadline, early refills with an unchanged deadline, confirmed
reset-credit use, and uncertain transitions. Records are available from the history strip and comparison card in both the
popover and Workbench. The compact list shares its detail-popover shell with
cost analytics.

Codex's reset-credit endpoint supplies all available expiry dates and confirmed
`redeemed_at` receipts. The UI lists each expiry. Only a confirmed redemption in
a short matching observation interval attributes a quota transition to a credit;
a falling available count alone cannot. Unmatched receipts remain visible in
the journal. Earlier cycles remain readable, with missing details marked.

## Isolated demo

```sh
python3 Scripts/chatgpt_chat_preview.py --output /tmp/vibebar-chat-preview
VIBEBAR_REVIEW_BUILD=1 ./Scripts/build_app.sh release
open ".build/Vibe Bar Chat Review.app"
```

The review app has a separate identity, `com.astroqore.VibeBar.ChatReview`, and
uses synthetic data with provider polling disabled. It coexists with the
installed app. No merge or release is implied by building this demo.

The localization catalog carries the allowance, reset-record, history,
and subscription-format strings; see `Package.swift` for the pinned version.
