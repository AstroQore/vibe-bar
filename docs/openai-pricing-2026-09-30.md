# OpenAI plans and speed pricing

Verified 2026-09-30, Asia/Shanghai. Subscription quota consumption and
API-equivalent token cost are separate quantities in Vibe Bar.

## Plans

The current subscription names are ChatGPT Pro 100, Pro 200 and Pro 500.
The display mapper accepts explicit price-tier names and ids. Existing
`prolite` / `pro5x` ids display as Pro 100; existing `pro` / `pro20x` ids
display as Pro 200. The raw account identity remains unchanged.

The marketing names do not establish every wire id. In particular,
`promax` displays as Pro Max, without assigning a price. Pro 500 requires
an explicit `pro500`, `pro_500`, `Pro 500` or equivalent price-tier label.
The subscription label formats retain the numeric price tier because it
is part of the plan name, rather than a quota multiplier.

Sources: [ChatGPT pricing](https://learn.chatgpt.com/docs/pricing),
[ChatGPT Pro tiers](https://help.openai.com/en/articles/9793128-about-chatgpt-pro-tiers).

## API-equivalent rates

USD per one million tokens, in Standard mode:

| Model | Input | Cached input | Cache write | Output | Fast |
| --- | ---: | ---: | ---: | ---: | ---: |
| GPT-6.1 Sol | 2 | 0.10 | 2.50 | 10 | 2x |
| GPT-6 Sol | 2 | 0.20 | 2.50 | 10 | 2x |
| GPT-6 Luna | 0.10 | 0.01 | 0.125 | 0.50 | 2x |
| GPT-6 Astra | 10 | 1 | 12.50 | 50 | 2x |

Astra Ultrafast is a separate API rate card: 60 input, 6 cached input,
75 cache write and 300 output. Above 272,000 input tokens those rates are
120, 12, 150 and 450. The input threshold includes cached input and selects
the rates for the **entire request**, including output. Exactly 272,000
input tokens still uses the short-context rates.

The other new models have no published Ultrafast rate in the checked API
catalog; Sol 6.1 Ultrafast is described as coming later. Such requests
remain unpriced. A dated snapshot also needs its own published premium
rate; ordinary date normalization does not grant it Ultrafast.

For the four models above, Fast API cost is 2x Standard. Other models keep
their own published multiplier, including GPT-5.5 at 2.5x. Subscription
Fast consumption at 2.5x and Astra Ultrafast consumption at 8x are not API
prices; paid-credit multipliers are also a separate billing measure.

Sources: [OpenAI API pricing](https://developers.openai.com/api/docs/pricing),
[GPT-6 Astra](https://developers.openai.com/api/docs/models/gpt-6-astra),
[GPT-6.1 Sol](https://developers.openai.com/api/docs/models/gpt-6.1-sol),
[agent speed](https://learn.chatgpt.com/docs/agent-configuration/speed).

## Data channels and projections

The current refresh order remains the bundled floor, AstroQore supplement,
Portkey, models.dev and LiteLLM, followed by AstroQore corrections and local
overrides. Missing optional fields fall through to the lower-priority
card; an explicit local override supplies its own independent Ultrafast
card in USD per one million tokens.

The public catalogs were downloaded and compared with the official prices
on the verification date:

| Channel | Four new models | Astra Ultrafast | Current parser support |
| --- | --- | --- | --- |
| LiteLLM | All four | Full short and above-272K rates | Reads `*_ultrafast` and `*_above_272k_tokens` |
| models.dev | All four | Absent | Reads context tiers and optional `experimental.modes.ultrafast.cost` |
| Portkey | Astra, Sol and Luna | Absent | Existing Standard parser; other channels supply optional context/premium fields |
| AstroQore supplement | Supplementary coverage | Absent in the checked document | Reads an optional `pricing.ultrafast` card and preserves inherited cards |

Settings' effective price table groups Standard, Fast and Ultrafast under
one model in a dedicated service-tier column. It includes only published
tiers, derives Fast rates from the model's API-price multiplier, and shows
each tier's long-context prices in its help text. Model counts, filtering
and usage aggregation retain the model identity. `pricing.effective` keeps
the same model row with `fastMultiplier` and a camelCase `ultrafast` object,
including long-context prices. Rates describe an
API-equivalent local estimate; they do not claim the amount charged to a
subscription.

## Historic requests and cache upgrades

Codex costing prefers `service_tier` on the token event, then its turn
context. For older rollouts that omit it, the first new scan uses the
current top-level config or selected profile as an estimate, or `default`
when no tier is configured. The stored costing tier can be inferred: it
is not evidence of the original request's tier. Unknown explicit tiers
and unsupported Ultrafast requests remain unpriced rather than becoming
Standard requests.

Once assigned, the costing tier remains stable on cache reuse and when a
rollout grows. Matching uses the request's timestamp, model, token delta
and occurrence order; newly recorded explicit metadata takes precedence.

Pricing schema 2 rejects old merged and per-source caches that discarded
the new fields. Scan-cache schema 8 reparses Codex tiers once. The ledger's
`codex_costing_tier_v1` migration drops only Codex ingest fingerprints so
unchanged source files can update their existing detail rows; it preserves
retained rows and daily rollups.

`calculationVersion` stays at 5. Its old history-wipe mechanism would lose
days whose original logs have rotated away. Pricing fingerprints include
Ultrafast and context fields; `UsageEventLedger.repriceForPricingRevision`
reports exact per-day deltas, and `CostHistoryStore.applyPricingRevision`
applies decreases as well as increases to retained history. Rollups that
lost request boundaries cannot reconstruct premium or context-tier costs.

The regression tests cover price-tier names, official rate shapes, 272K
boundaries, unsupported tiers and snapshots, projections, cache rejection,
unchanged and growing rollouts, the one-time ledger replay, and decreasing
Ultrafast prices without clearing retained history.
