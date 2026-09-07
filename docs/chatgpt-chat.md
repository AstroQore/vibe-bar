# ChatGPT Chat allowances

ChatGPT Chat appears above ChatGPT Agentic under OpenAI. It tracks Image
Generation and Deep Research, and — when asked to — the GPT-6 Pro and
GPT-5.6 Sol Pro message allowances. Enable it in OpenAI settings; a Codex
login is enough, and the existing browser import or built-in login works
too. No browser extension is required.

## Defaults

Both switches — tracking Chat, and counting Pro model messages — are on.
The Chat account appears only when there is a credential it can use: the
Codex OAuth login or a chatgpt.com web session. `ChatGPTChatSettings` carries
a `defaultsVersion`; a settings file written under an older version takes the
current defaults once, and a choice made after that is kept.

## Estimated and confirmed totals

The adapter reads the service remainder and reset time. It tries the Codex
CLI's OAuth bearer first — the credential the Codex quota already reads — and
only then the web cookie and the WebView session, so a Codex login needs no
separate web login for Chat. It reuses Agentic's `/wham/usage` plan parser
through whichever Chat transport answered. There are no fixed feature totals.

The service never states a total, so two figures stand in for it. From the
first read, the largest remainder ever reported for the account and plan is
the estimate: the allowance is at least that, and on the day it refills it is
exactly that. Every read therefore shows a percentage, marked estimated, with
the service's own distance to the reset (rounded to whole days, or hours
below a day) as the window — a monthly allowance is a normal row on day one,
not a season of "learning". Three consistent observed reset boundaries with
the same remainder then confirm the total and its window and take the
estimate mark off. Reads must bracket the reported boundary and be close
enough to it to avoid treating a long offline gap as a fresh full allowance;
moving unused reset times do not count. A remainder above the confirmed
total raises the estimate and withdraws the confirmation. A changed account
or plan starts over; a read that could not name the plan keeps what is known.

Estimated and confirmed rows alike go through the standard quota row,
forecast, pace, history, menu bar and mini-window paths. A row with no
percentage at all draws a still, dashed track.

## Pro model messages

The service reports no count for GPT-6 Pro or GPT-5.6 Sol Pro. Its
`conversation/init` reply names a model only once it is exhausted
(`model_limits`: `model_slug`, `resets_after`, `using_default_model_slug`),
and `/backend-api/models` carries no allowance fields. What OpenAI publishes
is the total per plan, in "GPT-5.6 and GPT-6 Pro in ChatGPT" (help article
20001354, read 2026-09-07):

Every Chat bucket is grouped the way Codex's Spark lanes are: the thing
being metered is the group header — Image Generation, Deep Research,
GPT-6 Astra Pro, GPT-5.6 Sol Pro, Pro Models — and its window (Daily,
Weekly, Monthly) is the row. A feature whose window is not known yet keeps
the feature name as its row and has no group.

| Plan | GPT-6 Astra Pro | GPT-5.6 Sol Pro |
| --- | --- | --- |
| Pro $200 (`pro`) | 200 messages per week | 170 per day; both models together 200 per day |
| Pro $100 (`prolite`) | one shared allowance of 50 messages per week | |

"Sync saved Chat history across devices" in OpenAI settings is the switch,
on by default. The reader lists the account's saved conversations
newest first, stops at the first one not updated inside the last week, skips
Work rows (`conversation_origin` `tpp` or `flora`) and temporary chats, and
fetches only conversations whose revision changed, at most 24 per refresh
and within 25 seconds. Each user turn is charged to the model of its final
answer, once, however often it was regenerated. Only hashed ids, times and
model slugs are cached, under `~/.vibebar/chatgpt_chat_history.json`.

Each bucket is the count inside a window ending now, against the published
total, marked estimated. Its reset is the moment the count next falls: the
oldest message still inside the window, plus the window — and a whole window
from now when nothing has been spent. That is the rolling shape the service
itself reports for the feature allowances it does time, and it gives the Pro
rows the same pace, forecast and reset history every other quota row has.
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
