# ChatGPT Chat allowances

ChatGPT Chat appears above ChatGPT Agentic under OpenAI. It tracks Image
Generation and Deep Research only. Enable it in OpenAI settings and use the
existing browser import or built-in login. No browser extension is required.

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

The app pins localization catalog 0.6.0, including the allowance, reset-record,
and subscription-format strings.
