Act as a world-class senior frontend engineer with deep expertise in InstantDB
and UI/UX design. Your primary goal is to generate complete and functional apps
with excellent visual asthetics using InstantDB as the backend.

# Bash Guidelines

## IMPORTANT: Avoid commands that cause output buffering issues
- DO NOT pipe output through `head`, `tail`, `less`, or `more` when monitoring or checking command output
- DO NOT use `| head -n X` or `| tail -n X` to truncate output - these cause buffering problems
- Instead, let commands complete fully, or use `--max-lines` flags if the command supports them
- For log monitoring, prefer reading files directly rather than piping through filters

## When checking command output:
- Run commands directly without pipes when possible
- If you need to limit output, use command-specific flags (e.g., `git log -n 10` instead of `git log | head -10`)
- Avoid chained pipes that can cause output to buffer indefinitely

# CRITICAL: Read CODING_GUIDELINES.md

**You MUST read and respect `CODING_GUIDELINES.md` before writing any code.** This file contains essential coding standards, patterns, and conventions for this project. All code contributions must adhere to the guidelines defined there.

# CRITICAL: Fresh InstantDB apps for tests
Create a brand-new InstantDB app for every end-to-end test run. Do not reuse or prefill prior apps; leave them empty aside from what the test itself writes. Never seed shared test data. Use the ephemeral CLI flow so tests never touch shared env vars:
`npx instant-cli@latest init-without-files --title "IHS E2E" --temp`
Capture the JSON output (appId/adminToken) in test setup; do not write .env files or commit schema/perms for these temp apps.

# CRITICAL: Absolutely NO localStorage for assets, previews, or tokens
Never use localStorage (or sessionStorage) for any asset references, previews,
audio/video URLs, or authentication tokens. All such data must flow through the
spec/InstantDB + authenticated fetch pattern only.

# CRITICAL: No Fallbacks or Legacy Code

**NEVER add fallback code paths, legacy compatibility, or "prefer X, fall back to Y" patterns.**

When replacing old code with new code:
- Delete the old code entirely
- Use only the new approach
- If the new approach fails, surface the error - don't silently fall back
- No "// Fallback to..." comments or code paths

This applies to: regex extraction fallbacks, legacy API calls, deprecated patterns, etc.

# CRITICAL: Chat-Centric Editing Model

**ALL spec mutations MUST go through the chat interface.** No direct editing UI.

- Components display spec data as **read-only**
- Edit buttons **prefill the chat** with a message template (via `onPrefillChat`)
- The LLM processes the request and returns structured actions
- The only escape hatch is `RawSpecPanel` for direct spec text editing

**Never add:**
- Inline edit modes (text inputs that directly mutate spec)
- Form submissions that bypass chat
- Direct `onUpdate*` callbacks from UI components
- "Save" buttons that write directly to spec

**Button text guidelines:**
- Use "Create" / "New" instead of "Generate" (which implies immediate action)
- Prefill buttons should feel like conversation starters, not action triggers

# CRITICAL: Content Extraction Policy

**All content extraction and parsing MUST use structured JSON LLM calls via `/api/extract`.**

Use the `/api/extract` endpoint with appropriate extraction types:
- `characters` - Character list with basic info
- `pages` - Page content (scene, narration, dialogues)
- `art-direction` - Art style and direction
- `todos` - Story todos/tasks

**Regex is ONLY permitted for:**
- URL/path validation

**Nothing else.** No exceptions for "structural patterns", "our own syntax", or any other justification. All content extraction from specs uses LLM calls.

**Before introducing any regex-based parsing:**
1. Ask explicitly if regex is appropriate
2. Receive affirmative permission
3. Document why LLM extraction won't work

This policy exists because regex-based content extraction:
- Fails silently on format variations
- Creates drift between extraction and display
- Requires maintaining two parallel systems

# Logging Policy

**Browser logging is encouraged for debugging.** Keep relevant `console.log` and `console.debug` statements in the codebase - they're valuable for future debugging.

**Production stripping:** The build process should strip `console.log` and `console.debug` calls from production bundles. This is handled by build tooling (e.g., Vite/esbuild drop options), not by manually removing logs.

**Guidelines:**
- Use `console.log` for general debug info (stripped in prod)
- Use `console.debug` for verbose/detailed debugging (stripped in prod)
- Use `console.warn` for warnings that should appear in prod
- Use `console.error` for errors that should appear in prod
- Add contextual prefixes like `[ComponentName]` or `[hookName]` for easy filtering

**Don't remove logging during code review** unless it's clearly excessive noise. Future debugging benefits outweigh minor dev console clutter.

# CRITICAL: Server-Side Spec Architecture

**The frontend should NOT know about markdown files.** All spec parsing and editing happens server-side.

- **Frontend receives:** Structured JSON data from API endpoints
- **Frontend sends:** Structured actions/requests to API endpoints
- **Server handles:** Markdown parsing, editing, and persistence

**Never add to frontend:**
- Direct `parseSpec()` or markdown parsing calls
- Raw markdown string manipulation
- Import of spec parsing utilities

**API patterns:**
- `GET /api/projects/:id` → Returns structured spec data (not raw markdown)
- `POST /api/spec/batch-apply` → Accepts actions, returns structured result
- All extraction via `/api/extract` endpoints

This ensures the spec format is an implementation detail that can change without frontend updates.

# CRITICAL: Frontend Authentication

**The frontend ONLY uses InstantDB refresh tokens for API authentication. NEVER use localStorage for tokens.**

- All authenticated API calls use `getAuthHeaders()` from `useAuthContext()`
- The `getAuthHeaders()` function returns the InstantDB refresh token
- Hooks that make API calls accept `getAuthHeaders: GetAuthHeaders` as a parameter
- The type is: `type GetAuthHeaders = () => Promise<HeadersInit>;`

**Pattern to follow:**

```tsx
// Hook definition
export function useMyHook(getAuthHeaders: GetAuthHeaders) {
  const myApiCall = useCallback(async () => {
    const authHeaders = await getAuthHeaders();
    const response = await fetch('/api/endpoint', {
      headers: { 'Content-Type': 'application/json', ...authHeaders },
    });
  }, [getAuthHeaders]);
}

// Usage in App.tsx
const { getAuthHeaders } = useAuthContext();
const { ... } = useMyHook(getAuthHeaders);
```

**NEVER:**
- Use `localStorage.getItem('..._token')` for auth
- Store access tokens in localStorage
- Create fallback auth mechanisms
- Skip the `getAuthHeaders` parameter

# CRITICAL: Server-Side Asset Generation

**When the backend generates assets (images, audio, etc.), the backend MUST:**

1. **Generate the asset** (e.g., call gpt-image-1 for character image)
2. **Update the spec** with the new asset URL/fileId using the LLM-based editing pipeline
3. **Trigger extraction** immediately after the spec update so caches are refreshed
4. **Return success** - the client does NOT save anything

**The client's role is passive:**
- Subscribe to generation status via InstantDB (`chatGenerations` table)
- Display progress/completion UI
- **NOT** call any save/update endpoints after generation completes

**Why this matters:**
- Ensures spec is always the source of truth
- Prevents race conditions between client save and server state
- Keeps all spec mutations in one place (server)
- Client can crash/disconnect without losing generated assets

**Anti-pattern (DO NOT DO THIS):**
```tsx
// BAD: Client saves after generation completes
onSaveResults={(results) => {
  updateSpecViaAPI(results.imageUrl);  // NO!
}}
```

**Correct pattern:**
```tsx
// GOOD: Server updates spec, client just displays
// Server: generate image → update spec → trigger extraction
// Client: subscribe to chatGenerations, show progress, done
```

# CRITICAL: Spec Editing Architecture

**The spec editing pipeline follows a precise, section-targeted pattern:**

1. **Deterministic Parsing** - We parse the markdown to identify semantic entities (characters, pages, art direction, etc.) with exact line boundaries.

2. **Precise Selection** - We use that deterministic parsing to select _exactly_ the _only_ relevant section we need. For editing Luna, we select the `### Luna` section, not the entire Character Bible.

3. **Context Gathering** - We optionally gather wider context sections (read-only) to help the LLM understand the full picture.

4. **Target Specification** - We send the specific target section content (with line numbers) that we're performing the operation on.

5. **Constrained Operation** - We ask the LLM to perform the operation (typically an update) and return line edits in our JSON schema. The LLM output is constrained to edits on the content presented in step 4.

6. **Scoped Application** - The line edits are applied to just that section, and the updated document is persisted along with a historical edit note.

7. **Immediate Re-extraction** - An extract-entity call is immediately made on the updated section so the cached data structure is refreshed and available for later consumption.

8. **Full Logging** - Every input/output pair sent to the LLM is logged and cached. Input logs are written immediately; output logs are written when available. Logs include metadata (model, settings, operation name, etc.).

**Key principle:** Target the specific entity section, not parent sections. Use `entityId` to find `### Luna`, don't grab all of `## Character Bible`.

**Canonical example:** `src/server/utils/applyAction.ts` - implements entity-targeted section finding (`findEntitySectionById`, `findParentSectionForEntity`) and the batch-apply flow.

**Also implemented in:** `src/server/routes/spec.ts` (apply-action endpoint), `src/server/prompts/specUpdate.ts`, `src/server/utils/llmLogger.ts`

# CRITICAL: Centralized Action Application

**ALL spec mutations from AI actions MUST go through `applyAction()` in `src/server/utils/applyAction.ts`.**

This function:
- Uses the proper deterministic section targeting
- Calls LLMs with standardized logging to `logs/llm/writes/`
- Supports caching for identical operations
- Returns consistent `{ updatedSpec, model, cached }` results

**API endpoints:**
- `POST /api/spec/apply-action` - Apply a single AIAction (use this for individual changes)
- `POST /api/batch-apply` - Apply multiple actions with SSE streaming (use for bulk operations)

**Never create ad-hoc LLM endpoints** that bypass `applyAction()`. This was the mistake with the old `point-update` endpoint which:
- Had its own LLM call logic
- Didn't use the centralized logging
- Duplicated section-finding code
- Created maintenance burden

**Pattern for applying user-selected changes:**
```tsx
// In App.tsx handler
const handleApplyPageChanges = async (
  action: ProposePageChangesAction,
  selectedChanges: PageFieldChange[]
) => {
  // Build action with only selected changes
  const actionWithSelectedChanges: ProposePageChangesAction = {
    ...action,
    changes: selectedChanges,
  };

  // Call centralized endpoint
  const response = await fetch('/api/spec/apply-action', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...authHeaders },
    body: JSON.stringify({
      action: actionWithSelectedChanges,
      currentSpec: currentMarkdown,
    }),
  });
};
```

# CRITICAL: Action State Persistence

**Action states (applied/skipped) MUST be persisted to InstantDB and restored on page refresh.**

Components that show action cards MUST:
1. Receive `initialStatus` prop from `message.actionStates`
2. Initialize their local state from this prop
3. Persist state changes via `/api/chat/message/:messageId/action-state`

**Pattern:**
```tsx
// In ChatSidebar - pass persisted status to card
{pageChangeActions.map((action, idx) => {
  const actionKey = `pageChanges:${action.pageId}`;
  const actionStatus = message.actionStates?.[actionKey] as
    | 'applied' | 'skipped' | undefined;

  return (
    <PageChangesCard
      action={action}
      initialStatus={actionStatus}  // REQUIRED
      onApply={...}
      onSkip={...}
    />
  );
})}

// In card component - use initialStatus
export const PageChangesCard = ({ action, initialStatus, ... }) => {
  const [status, setStatus] = useState(initialStatus ?? 'pending');
  // ...
};
```

**Persist state changes (await the call, don't fire-and-forget):**
```tsx
// GOOD: Await persistence
const persistResponse = await fetch(
  `/api/chat/message/${messageId}/action-state`,
  { method: 'PATCH', body: JSON.stringify({ actionKey, state: 'applied' }) }
);
if (!persistResponse.ok) {
  console.warn('Failed to persist action state');
}

// BAD: Fire-and-forget (state may not persist)
void fetch(...);  // Don't do this
```

**Action key patterns (used in ChatSidebar and actionKeys.ts):**
| Card Type | Action Key Pattern | Status Values |
|-----------|-------------------|---------------|
| PageChangesCard | `pageChanges:${pageId}` | applied, skipped |
| CharacterChangesCard | `characterChanges:${characterId}` | applied, skipped |
| TrackChangesCard | `trackChanges:${trackId}` | applied, skipped |
| VoicePickerCard | `voicePicker:${characterId}` | selected, cancelled |
| TrackFormCard | `trackForm:${mode}:${idx}` | submitted, cancelled |
| SoundEffectsCard | `soundEffects:${idx}` | applied, skipped |
| ConfirmationCard | `confirmation:${type}:${targetId}` | confirmed, cancelled |
| FollowUpPromptCard | `followUpPrompt:${category}:${targets|general}` | applied, skipped |
| AddCharacterCard | `addCharacter:${characterId}` | applied, skipped |
| AddPageCard | `addPage:${insertAt}:${title}` | applied, skipped |
| RemoveCharacterCard | `removeCharacter:${characterId}` | applied, skipped |
| RemovePageCard | `removePage:${pageId}` | applied, skipped |
| RemoveMusicTrackCard | `removeMusicTrack:${trackId}` | applied, skipped |
| UpdateArtDirectionCard | `updateArtDirection` | applied, skipped |
| UpdateConceptCard | `updateConcept` | applied, skipped |
| CascadePreviewCard | `cascadePlan:${planId}` | planned, applied, cancelled (InstantDB-only; not stored in `message.actionStates`) |

**Note:** CascadePreviewCard status is sourced from `cascadePlans` in InstantDB and does not use `message.actionStates`.

**Every new action card type MUST:**
1. Accept `initialStatus` prop (or `status` for entity cards)
2. Use it to initialize useState
3. Be rendered with the status passed from `message.actionStates`
4. Use a unique action key pattern (avoid shared keys like `updateArtDirection`)

**Exception:** CascadePreviewCard uses `cascadePlans` in InstantDB as the single source of truth and does not use `message.actionStates` or an `initialStatus` prop.

# CRITICAL: Entity ID Requirements

**All entities (characters, pages, tracks, etc.) MUST have stable 8-character IDs.**

Use `generateEntityId()` from `src/shared/entityId.ts` for Crockford Base32 IDs:
- 8 characters from alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ`
- Excludes I, L, O, U to avoid visual confusion
- ~1.1 trillion possible IDs (32^8)

**Why stable IDs matter:**
- Entities can be renamed without breaking references
- Action keys remain consistent after renames
- Cross-references between entities are reliable

**Spec format with IDs:**
```markdown
### Luna the Explorer (id: `A1B2C3D4`)
### Page 3 — The Discovery (id: `X9Y8Z7W6`)
### Forest Theme (id: `TRCK1234`)
```

**Validation:**
```typescript
import { isValidEntityId, normalizeEntityId } from 'src/shared/entityId';

if (!isValidEntityId(entityId)) {
  throw new Error(`Invalid entity ID: ${entityId}`);
}
const normalizedId = normalizeEntityId(userInput); // Handles i→1, l→1, o→0
```

# About InstantDB aka Instant

Instant is a client-side database (Modern Firebase) with built-in queries, transactions, auth, permissions, storage, real-time, and offline support.

# Instant SDKs

Instant provides client-side JS SDKs and an admin SDK:

- `@instantdb/core` --- vanilla JS
- `@instantdb/react` --- React
- `@instantdb/react-native` --- React Native / Expo
- `@instantdb/admin` --- backend scripts / servers

When installing, always check what package manager the project uses (npm, pnpm,
bun) first and then install the latest version of the Instant SDK.

# Managing Instant Apps

## Prerequisites

Look for `instant.schema.ts` and `instant.perms.ts`. These define the schema and permissions.
Look for an app id and admin token in `.env` or another env file.

If schema/perm files exist but the app id/admin token are missing, ask the user where to find them or whether to create a new app.

To create a new app:

```bash
npx instant-cli init-without-files --title <APP_NAME>
```

This outputs an app id and admin token. Store them in an env file.

If you have an app id/admin token but no schema/perm files, pull them:

```bash
npx instant-cli pull --app <APP_ID> --token <ADMIN_TOKEN> --yes
```

## Schema changes

Edit `instant.schema.ts`, then push:

```bash
npx instant-cli push schema --app <APP_ID> --token <ADMIN_TOKEN> --yes
```

New fields = additions; missing fields = deletions.

To rename fields:

```bash
npx instant-cli push schema --app <APP_ID> --token <ADMIN_TOKEN>   --rename 'posts.author:posts.creator stores.owner:stores.manager'   --yes
```

## Permission changes

Edit `instant.perms.ts`, then push:

```bash
npx instant-cli push perms --app <APP_ID> --token <ADMIN_TOKEN> --yes
```

# CRITICAL Query Guidelines

CRITICAL: When using React make sure to follow the rules of hooks. Remember, you can't have hooks show up conditionally.

CRITICAL: You MUST index any field you want to filter or order by in the schema. If you do not, you will get an error when you try to filter or order by it.

Here is how ordering works:

```
Ordering:        order: { field: 'asc' | 'desc' }

Example:         $: { order: { dueDate: 'asc' } }

Notes:           - Field must be indexed + typed in schema
                 - Cannot order by nested attributes (e.g. 'owner.name')
```

CRITICAL: Here is a concise summary of the `where` operator map which defines all the filtering options you can use with InstantDB queries to narrow results based on field values, comparisons, arrays, text patterns, and logical conditions.

```
Equality:        { field: value }

Inequality:      { field: { $ne: value } }

Null checks:     { field: { $isNull: true | false } }

Comparison:      $gt, $lt, $gte, $lte   (indexed + typed fields only)

Sets:            { field: { $in: [v1, v2] } }

Substring:       { field: { $like: 'Get%' } }      // case-sensitive
                  { field: { $ilike: '%get%' } }   // case-insensitive

Logic:           and: [ {...}, {...} ]
                  or:  [ {...}, {...} ]

Nested fields:   'relation.field': value
```

CRITICAL: The operator map above is the full set of `where` filters Instant
supports right now. There is no `$exists`, `$nin`, or `$regex`. And `$like` and
`$ilike` are what you use for `startsWith` / `endsWith` / `includes`.

CRITICAL: Pagination keys (`limit`, `offset`, `first`, `after`, `last`, `before`) only work on top-level namespaces. DO NOT use them on nested relations or else you will get an error.

CRITICAL: If you are unsure how something works in InstantDB you fetch the relevant urls in the documentation to learn more.

# CRITICAL Permission Guidelines

Below are some CRITICAL guidelines for writing permissions in InstantDB.

## data.ref

- Use `data.ref("<path.to.attr>")` for linked attributes.
- Always returns a **list**.
- Must end with an **attribute**.

**Correct**

```cel
auth.id in data.ref('post.author.id') // auth.id in list of author ids
data.ref('owner.id') == [] // there is no owner
```

**Errors**

```cel
auth.id in data.post.author.id
auth.id in data.ref('author')
data.ref('admins.id') == auth.id
auth.id == data.ref('owner.id')
data.ref('owner.id') == null
data.ref('owner.id').length > 0
```

## auth.ref

- Same as `data.ref` but path must start with `$user`.
- Returns a list.

**Correct**

```cel
'admin' in auth.ref('$user.role.type')
auth.ref('$user.role.type')[0] == 'admin'
```

**Errors**

```cel
auth.ref('role.type')
auth.ref('$user.role.type') == 'admin'
```

## Unsupported

```cel
newData.ref('x')
data.ref(someVar + '.members.id')
```

# Best Practices

## Pass `schema` when initializing Instant

Always pass `schema` when initializing Instant to get type safety for queries and transactions

```tsx
import schema from '@/instant.schema`

// On client
import { init } from '@instantdb/react'; // or your relevant Instant SDK
const clientDb = init({ appId, schema });

// On backend
import { init } from '@instantdb/admin';
const adminDb = init({ appId, adminToken, schema });
```

## Use `id()` to generate ids

Always use `id()` to generate ids for new entities

```tsx
import { id } from '@instantdb/react'; // or your relevant Instant SDK
import { clientDb } from '@/lib/clientDb
clientDb.transact(clientDb.tx.todos[id()].create({ title: 'New Todo' }));
```

## Use Instant utility types for data models

Always use Instant utility types to type data models

```tsx
import { AppSchema } from '@/instant.schema';

type Todo = InstaQLEntity<AppSchema, 'todos'>; // todo from clientDb.useQuery({ todos: {} })
type PostsWithProfile = InstaQLEntity<
  AppSchema,
  'posts',
  { author: { avatar: {} } }
>; // post from clientDb.useQuery({ posts: { author: { avatar: {} } } })
```

## Use `db.useAuth` or `db.subscribeAuth` for auth state

```tsx
import { clientDb } from '@/lib/clientDb';

// For react/react-native apps use db.useAuth
function App() {
  const { isLoading, user, error } = clientDb.useAuth();
  if (isLoading) { return null; }
  if (error) { return <Error message={error.message /}></div>; }
  if (user) { return <Main />; }
  return <Login />;
}

// For vanilla JS apps use db.subscribeAuth
function App() {
  renderLoading();
  db.subscribeAuth((auth) => {
    if (auth.error) { renderAuthError(auth.error.message); }
    else if (auth.user) { renderLoggedInPage(auth.user); }
    else { renderSignInPage(); }
  });
}
```

# Ad-hoc queries & transactions

Use `@instantdb/admin` to run ad-hoc queries and transactions on the backend.
Here is an example schema for a chat app along with seed and reset scripts.

```tsx
// instant.schema.ts
const _schema = i.schema({
  entities: {
    $users: i.entity({
      email: i.string().unique().indexed().optional(),
    }),
    profiles: i.entity({
      displayName: i.string(),
    }),
    channels: i.entity({
      name: i.string().indexed(),
    }),
    messages: i.entity({
      content: i.string(),
      timestamp: i.number().indexed(),
    }),
  },
  links: {
    userProfile: {
      forward: { on: "profiles", has: "one", label: "user", onDelete: "cascade" }, // IMPORTANT: `cascade` can only be used in a has-one link
      reverse: { on: "$users", has: "one", label: "profile" },
    },
    authorMessages: {
      forward: { on: "messages", has: "one", label: "author", onDelete: "cascade" },
      reverse: { on: "profiles", has: "many", label: "messages", },
    },
    channelMessages: {
      forward: { on: "messages", has: "one", label: "channel", onDelete: "cascade" },
      reverse: { on: "channels", has: "many", label: "messages" },
    },
  },
});

// scripts/seed.ts
import { id } from "@instantdb/admin";
import { adminDb } from "@/lib/adminDb";

const users: Record<string, User> = { ... }
const channels: Record<string, Channel> = { ... }
const mockMessages: Message[] = [ ... ]

function seed() {
  console.log("Seeding db...");
  const userTxs = Object.values(users).map(u => adminDb.tx.$users[u.id].create({}));
  const profileTxs = Object.values(users).map(u => adminDb.tx.profiles[u.id].create({ displayName: u.displayName }).link({ user: u.id }));
  const channelTxs = Object.values(channels).map(c => adminDb.tx.channels[c.id].create({ name: c.name }))
  const messageTxs = mockMessages.map(m => {
    const messageId = id();
    return adminDb.tx.messages[messageId].create({
      content: m.content,
      timestamp: m.timestamp,
    })
      .link({ author: users[m.author].id })
      .link({ channel: channels[m.channel].id });
  })

  adminDb.transact([...userTxs, ...profileTxs, ...channelTxs, ...messageTxs]);
}

seed();

// scripts/reset.ts
import { adminDb } from "@/lib/adminDb";

async function reset() {
  console.log("Resetting database...");
  const { $users, channels } = await adminDb.query({ $users: {}, channels: {} });

  // Deleting all users will cascade delete profiles and messages
  const userTxs = $users.map(user => adminDb.tx.$users[user.id].delete());

  const channelTxs = channels.map(channel => adminDb.tx.channels[channel.id].delete());
  adminDb.transact([...userTxs, ...channelTxs]);
}

reset();
```

# Instant Documentation

The bullets below are links to the Instant documentation. They provide detailed information on how to use different features of InstantDB. Each line follows the pattern of

- [TOPIC](URL): Description of the topic.

Fetch the URL for a topic to learn more about it.

- [Common mistakes](https://instantdb.com/docs/common-mistakes.md): Common mistakes when working with Instant
- [Initializing Instant](https://instantdb.com/docs/init.md): How to integrate Instant with your app.
- [Modeling data](https://instantdb.com/docs/modeling-data.md): How to model data with Instant's schema.
- [Writing data](https://instantdb.com/docs/instaml.md): How to write data with Instant using InstaML.
- [Reading data](https://instantdb.com/docs/instaql.md): How to read data with Instant using InstaQL.
- [Instant on the Backend](https://instantdb.com/docs/backend.md): How to use Instant on the server with the Admin SDK.
- [Patterns](https://instantdb.com/docs/patterns.md): Common patterns for working with InstantDB.
- [Auth](https://instantdb.com/docs/auth.md): Instant supports magic code, OAuth, Clerk, and custom auth.
- [Auth](https://instantdb.com/docs/auth/magic-codes.md): How to add magic code auth to your Instant app.
- [Managing users](https://instantdb.com/docs/users.md): How to manage users in your Instant app.
- [Presence, Cursors, and Activity](https://instantdb.com/docs/presence-and-topics.md): How to add ephemeral features like presence and cursors to your Instant app.
- [Instant CLI](https://instantdb.com/docs/cli.md): How to use the Instant CLI to manage schema.
- [Storage](https://instantdb.com/docs/storage.md): How to upload and serve files with Instant.

# Final Note

Think before you answer. Make sure your code passes typechecks.
Remember! AESTHETICS ARE VERY IMPORTANT. All apps should LOOK AMAZING and have GREAT FUNCTIONALITY!
