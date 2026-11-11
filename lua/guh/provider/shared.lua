--- Provider-neutral helpers shared by the GitHub and GitLab backends.
---
--- Both backends normalize their vocabulary into these shapes, so the render/UI layer
--- (`guh.pr`, `guh.comments`, `guh.state`) can treat them identically:
---
--- - `pr.state`       -> "OPEN" | "CLOSED" | "MERGED" (GitLab "opened"/"closed"/"merged"/"locked")
--- - `pr.isDraft`     -> boolean (GitLab `draft`)
--- - `job.conclusion` -> "success" | "failure" | "cancelled" | "skipped" | "neutral", or nil while running

local M = {}

--- PR-state highlights. Open=green, Closed=red, Merged=blue (Draft falls through to default).
M.state_hl = { Open = 'OkMsg', Closed = 'ErrorMsg', Merged = 'DiagnosticHint' }

--- GitHub GraphQL `reactionGroups[].content` → emoji.
M.reaction_emoji = {
  THUMBS_UP = '👍',
  THUMBS_DOWN = '👎',
  LAUGH = '😄',
  HOORAY = '🎉',
  CONFUSED = '😕',
  HEART = '❤️',
  ROCKET = '🚀',
  EYES = '👀',
}

--- GitLab award-emoji `name` → emoji. (GitLab names are lowercase and only overlap GitHub's
--- vocabulary partially; `thumbsup`/`thumbsdown` are the notable spellings.)
M.gitlab_reaction_emoji = {
  thumbsup = '👍',
  thumbsdown = '👎',
  laughing = '😄',
  tada = '🎉',
  confused = '😕',
  heart = '❤️',
  rocket = '🚀',
  eyes = '👀',
}

--- "Open" | "Draft" | "Closed" | "Merged" | "?".
--- @param pr PullRequest
function M.pr_state_label(pr)
  return pr.isDraft and 'Draft' or (pr.state and (pr.state:sub(1, 1) .. pr.state:sub(2):lower()) or '?')
end

--- Status emoji for a CI job.
--- @param job CIJob
function M.ci_icon(job)
  if not job.conclusion then
    return '⏳' -- No `conclusion` until job finishes (still-running / in-progress).
  elseif job.conclusion == 'success' or job.conclusion == 'neutral' or job.conclusion == 'skipped' then
    return '✅'
  end
  return '❌'
end

--- JSON-decodes `str`, returning `default` if it is not valid JSON.
---
--- @param str string
--- @param default any
function M.parse_or_default(str, default)
  local success, result = pcall(vim.json.decode, str, { luanil = { object = true, array = true } })
  if success then
    return result
  end
  return default
end

--- Formats an ISO-8601 timestamp as a relative "… ago" string (largest unit only, like gh's
--- `timeago`). Returns "" for an empty/unparseable value.
---
--- @param iso string?
--- @return string
function M.reltime(iso)
  local t = iso and vim.fn.strptime('%Y-%m-%dT%H:%M:%S', iso) or 0
  if t == 0 then
    return '' -- empty / unparseable
  end
  local full = require('vim._core.time').fmt_rtime(math.max(0, os.time() - t))
  return full:match('^[^,]+') .. ' ago' -- Keep only the first (largest) unit.
end

--- Counts added/removed lines in a unified diff. Used by providers that don't report a diffstat
--- (GitLab's MR object has no additions/deletions).
---
--- @param diff string
--- @return integer additions
--- @return integer deletions
function M.diffstat(diff)
  local add, del = 0, 0
  for line in (diff or ''):gmatch('[^\n]+') do
    if line:sub(1, 1) == '+' and not line:match('^%+%+%+') then
      add = add + 1
    elseif line:sub(1, 1) == '-' and not line:match('^%-%-%-') then
      del = del + 1
    end
  end
  return add, del
end

return M
