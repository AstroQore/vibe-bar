# ChatGPT Chat — review build

This integration lives under **OpenAI → ChatGPT Chat**, separately from
**ChatGPT Agentic**. It is opt-in in Settings → OpenAI and does not import
Codex/Work token costs or local agent transcripts.

## Connect

1. Enable **Track ChatGPT Chat** in Settings → OpenAI.
2. Use the existing **Import from browser** or **Open WebView login** controls.
   macOS may require the user to authorize the app's credential access.
3. Refresh Chat allowances. The adapter first reuses cookies already authorized
   by Vibe Bar. If direct HTTP cannot authenticate, it tries the same first-party
   WebView profile used by OpenAI login. No Chrome extension or localhost server
   is required by this implementation.
4. Optionally enable saved cloud-history sync. It reads active and archived
   conversations across devices, with a bounded incremental cache. Only model,
   time and hashed deduplication metadata are retained, never conversation text.

A new ad-hoc build does not necessarily inherit an older build's Keychain
access. A login-required result is not proof of a valid connection. The account
must return a successful first-party response before any new values are shown.

## Values and scope

- Image Generation and Deep Research display the `limits_progress` service
  remainders and `reset_after`. These are allowance units, not a promise that
  one generation request costs one unit. No total or percentage is invented.
- Chat model counts are **history estimates**. Enter the actual limits of your
  plan (zero means unknown), and optionally the current reset times shown by
  ChatGPT. Otherwise the estimate uses the past 24 hours or seven days; that
  rolling window may differ from the provider's billing window.
- The account's `/models` response distinguishes Pro from Thinking and carries
  `is_work_mode_model`. In the verified schema, Astra Pro is `gpt-6-pro` and
  Sol Pro is `gpt-5-6-pro`; `gpt-5-6-thinking` remains a different model even at
  `max` effort. Other observed Chat models get their own rows.
- Work origins `tpp`, `flora`, and `codex`, Work catalog entries, and `-wm` /
  Codex models are excluded. Unknown origins are unclassified, not assumed Chat.
- One user message is associated with its successful final response through the
  conversation graph. Tool, reasoning and duplicate assistant nodes are not
  counted as separate user requests. Model changes follow the actual response,
  not merely the conversation's current default model.
- The first sync may span several refreshes. Missing pages, failed reads,
  unclassified turns and read bounds withhold remaining-message estimates.
  Temporary/deleted chats and regeneration billing can still differ from history.
- Temporary `WEB:` URLs are not used as server conversation IDs or Work flags.
  This collector consumes final IDs from cloud history and does not send prompts.

The menu-bar composer has a **Used / remaining count** metric. New Chat fields
select it by default. Percentage metrics are absent when a total is unknown;
absolute/estimated quantities do not feed percentage pace or reset-history models.

## Review without changing the installed app

```sh
python3 Scripts/chatgpt_chat_preview.py --output /tmp/vibebar-chat-preview
VIBEBAR_DEMO_HOME=/tmp/vibebar-chat-preview \
VIBEBAR_DEMO_SURFACE=popover:openAI VIBEBAR_DEMO_BACKDROP=1 \
  ".build/Vibe Bar.app/Contents/MacOS/VibeBar"
```

This is synthetic preview data. The isolated demo home disables provider polling,
updates, login-item registration and normal local runtime integration. Use the
regular build's OpenAI settings for actual sign-in, not the synthetic preview.

A separate read-only connection diagnostic starts no regular dashboard or quota
scheduler and prints only projected counts/status:

```sh
".build/Vibe Bar.app/Contents/MacOS/VibeBar" --chatgpt-chat-probe --webview-only
# Add --history to exercise bounded cloud-history collection.
# --cookie-only diagnoses the existing Keychain-backed cookie route instead.
```

The review branch pins the companion `vibe-bar-i18n` change to an immutable,
unmerged commit so a clean checkout can build. Replace that review revision with
the approved catalog release tag before merging or publishing. Neither repository
is merged or released as part of this review.

For a separate application identity that can coexist with the installed app:

```sh
python3 Scripts/chatgpt_chat_preview.py --output /tmp/vibebar-chat-preview
VIBEBAR_REVIEW_BUILD=1 ./Scripts/build_app.sh release
open ".build/Vibe Bar Chat Review.app"
```

The review bundle uses `com.astroqore.VibeBar.ChatReview`, removes URL-scheme
registration, and points Launch Services at the isolated synthetic demo home.
It is for layout/quantity inspection. The ordinary `Vibe Bar.app` bundle retains
the production identifier and is the one to use for an actual login test.
