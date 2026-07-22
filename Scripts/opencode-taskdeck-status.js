// opencode → TaskDeck AI status bridge (plugin).
//
// Makes opencode sessions launched INSIDE a TaskDeck pane show up in the
// sidebar grouping, using the exact same status-file mechanism as the Claude
// Code hook (Scripts/taskdeck-ai-status.sh): it writes
//   ~/Library/Application Support/TaskDeck/status/<sessionID>.json
//   = {"session_id","state","ts","task"}
// via tmp+rename (the GUI watches the dir with kqueue, which only fires on
// create/delete/RENAME — an in-place truncate updates silently).
//
// State mapping (→ TaskDeck grouping):
//   chat.message / tool.execute.before  → "running"   (AI 執行中)
//   permission.ask                      → "permission"(等你 · 需授權)
//   session.idle / session.error        → "waiting"   (等你)
//   session.deleted                     → "ended"
//
// No-op unless TASKDECK_TASK is set — i.e. only opencode started by taskdeckd
// inside a task pane is tracked; opencode run anywhere else is ignored.
//
// Install: copied to ~/.config/opencode/plugin/taskdeck-status.js (auto-loaded
// globally). Escape hatch: `opencode --pure` runs without any plugin.
import { writeFileSync, renameSync, mkdirSync, appendFileSync } from "node:fs"
import { join } from "node:path"

const TASK = process.env.TASKDECK_TASK
const HOME = process.env.HOME || ""
const DIR = join(HOME, "Library", "Application Support", "TaskDeck", "status")
const DEBUG = !!process.env.TASKDECK_PLUGIN_DEBUG

// Per-session throttle state: one opencode process can host several sessions,
// so a shared scalar let session A's write suppress session B's.
const lastState = new Map()
const lastRunningWrite = new Map()

function dbg(...a) {
  if (!DEBUG) return
  try { appendFileSync(join(DIR, "..", "opencode-plugin.log"), `[${new Date().toISOString()}] ${a.join(" ")}\n`) } catch {}
}

function write(sid, state) {
  if (!TASK || !sid || String(sid).includes("/")) { dbg("skip", state, "sid=", sid); return }
  const now = Date.now() / 1000
  // Throttle repeated "running" writes; a state change always writes through.
  if (state === "running" && lastState.get(sid) === "running"
      && now - (lastRunningWrite.get(sid) || 0) < 2) return
  if (state === "running") lastRunningWrite.set(sid, now)
  lastState.set(sid, state)
  try {
    mkdirSync(DIR, { recursive: true })
    const rec = JSON.stringify({ session_id: sid, state, ts: now, task: TASK })
    const tmp = join(DIR, `.${sid}.json.tmp`)
    writeFileSync(tmp, rec)
    renameSync(tmp, join(DIR, `${sid}.json`))
    dbg("write", state, sid)
  } catch (e) { dbg("write-error", String(e)) }
}

// session.* events carry the id under properties; be defensive about shape.
function sidFromEvent(props) {
  if (!props || typeof props !== "object") return null
  return props.sessionID || props.session_id
      || props.info?.sessionID || props.info?.id
      || props.part?.sessionID || props.message?.sessionID || null
}

export const TaskDeckStatus = async () => {
  if (!TASK) return {} // not inside a TaskDeck pane → don't track
  dbg("plugin loaded, task=", TASK)
  return {
    "chat.message": async (input) => { write(input?.sessionID, "running") },
    "tool.execute.before": async (input) => { write(input?.sessionID, "running") },
    "permission.ask": async (input) => { write(input?.sessionID, "permission") },
    event: async ({ event }) => {
      const type = event?.type
      if (!type) return
      if (DEBUG && type.startsWith("session.")) dbg("event", type, "sid=", sidFromEvent(event?.properties))
      if (type === "session.idle" || type === "session.error") write(sidFromEvent(event?.properties), "waiting")
      else if (type === "session.deleted") write(sidFromEvent(event?.properties), "ended")
    },
  }
}
