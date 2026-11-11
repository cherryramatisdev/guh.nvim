--- Fixture tests for the GitLab backend. No network and no `glab` auth required: these exercise
--- the pure shape-mapping between GitLab API responses and the shared provider contract.

local n = require('test.functional.testnvim')()
local t = require('test.testutil')
local describe, it, before_each = t.describe, t.it, t.before_each

local test_cwd = assert(vim.uv.cwd())

before_each(function()
  n.clear()
  n.exec_lua(function(cwd_)
    vim.cmd.cd(cwd_)
    vim.opt.runtimepath:append { cwd_ }
  end, test_cwd)
end)

--- Shared fixtures: one MR with a resolved diff thread (+reply), a LEFT-side multiline thread, a
--- stale (outdated) thread, an overview note, and a system-only discussion.
local FIXTURES = [[
local repo = 'g/s/p'
local mr = {
  id = 12345,
  iid = 7,
  title = 'Add widget',
  description = 'Body text',
  state = 'opened',
  draft = false,
  created_at = '2026-01-01T10:00:00.000Z',
  source_branch = 'feat/widget',
  target_branch = 'main',
  sha = 'abc1234',
  web_url = 'https://git.ifoodcorp.com.br/g/s/p/-/merge_requests/7',
  author = { username = 'alice', name = 'Alice A' },
  diff_refs = { base_sha = 'base1', head_sha = 'head1', start_sha = 'start1' },
  head_pipeline = { id = 555 },
}
local discussions = {
  {
    id = 'disc1',
    notes = {
      { id = 1001, body = 'root comment', resolvable = true, resolved = true,
        updated_at = '2026-01-02T10:00:00.000Z', author = { username = 'alice' },
        position = { head_sha = 'head1', new_path = 'a.lua', old_path = 'a.lua', new_line = 5, old_line = 5 } },
      { id = 1002, body = 'a reply', resolvable = true, resolved = true,
        updated_at = '2026-01-02T11:00:00.000Z', author = { username = 'bob' },
        position = { head_sha = 'head1', new_path = 'a.lua', old_path = 'a.lua', new_line = 5, old_line = 5 } },
    },
  },
  {
    id = 'disc2',
    notes = {
      { id = 1003, body = 'gone', resolvable = true, resolved = false,
        updated_at = '2026-01-03T10:00:00.000Z', author = { username = 'carol' },
        position = { head_sha = 'head1', old_path = 'b.lua', new_path = 'b.lua', old_line = 3,
          line_range = { start = { old_line = 2 }, ['end'] = { old_line = 3 } } } },
    },
  },
  {
    id = 'disc3',
    notes = {
      { id = 1004, body = 'stale', resolvable = true, resolved = false,
        updated_at = '2026-01-04T10:00:00.000Z', author = { username = 'dave' },
        position = { head_sha = 'OLDHEAD', new_path = 'c.lua', new_line = 9 } },
    },
  },
  {
    id = 'disc4',
    notes = {
      { id = 1005, body = 'overview note', updated_at = '2026-01-05T10:00:00.000Z', author = { username = 'erin' } },
    },
  },
  { id = 'disc5', notes = { { id = 1006, system = true, body = 'changed label' } } },
}
local project = { default_branch = 'main', web_url = 'https://git.ifoodcorp.com.br/g/s/p' }
local commits = {
  { id = 'c1', title = 'first', message = 'first\n\nbody here', committed_date = '2026-01-01T09:00:00Z' },
}
local jobs = { { id = 11, name = 'rspec', status = 'failed', pipeline = { id = 555 } } }
local emoji = { { name = 'thumbsup' }, { name = 'thumbsup' }, { name = 'rocket' } }

return {
  repo = repo,
  mr = mr,
  discussions = discussions,
  project = project,
  commits = commits,
  jobs = jobs,
  emoji = emoji,
}
]]

describe('guh.provider.gitlab', function()
  it('implements the full github provider interface', function()
    n.exec_lua(function()
      local gh = require('guh.provider.github')
      local gl = require('guh.provider.gitlab')
      local missing = {}
      for k in pairs(gh) do
        if not k:match('^_') and gl[k] == nil then
          table.insert(missing, k)
        end
      end
      assert(#missing == 0, 'gitlab is missing: ' .. table.concat(missing, ', '))
    end)
  end)

  it('caps() reflects the documented GitLab limitations', function()
    n.exec_lua(function()
      local gl = require('guh.provider.gitlab').caps()
      assert(gl.viewed_state == false, 'viewed_state should be false (no public API)')
      assert(gl.admin_merge == false, 'admin_merge should be false (no --admin equivalent)')
      assert(gl.notifications == true, 'notifications supported via to-dos')
      assert(gl.multiline_comment == true, 'multiline supported via line_range')
      assert(gl.diff_in_pr_data == true, 'diff ships with pr_data (GitLab has no diffstat)')
    end)
  end)

  it('to_ci_jobs normalizes statuses, drops skipped, sorts by (status, name)', function()
    n.exec_lua(function()
      local jobs = require('guh.provider.gitlab')._to_ci_jobs({
        { id = 11, name = 'rspec', status = 'failed', pipeline = { id = 555 } },
        { id = 12, name = 'rubocop', status = 'success', pipeline = { id = 555 } },
        { id = 13, name = 'skipped-one', status = 'skipped', pipeline = { id = 555 } },
        { id = 14, name = 'deploy', status = 'running', pipeline = { id = 555 } },
      }, 555)
      assert(#jobs == 3, ('expected 3 jobs, got %d'):format(#jobs))
      assert(jobs[1].name == 'rspec', 'failure sorts first')
      assert(jobs[1].conclusion == 'failure', 'failed -> failure')
      assert(jobs[1].databaseId == 11, 'databaseId = job id')
      assert(jobs[1].runId == 555, 'runId = pipeline id')
      assert(jobs[3].conclusion == 'success', 'success -> success')
      assert(jobs[2].conclusion == nil, 'running has no conclusion (pending)')
    end)
  end)

  it('to_pr maps a GitLab MR to the shared PullRequest shape', function()
    n.exec_lua(function()
      local gl = require('guh.provider.gitlab')
      local f = load(FIXTURES)()
      local pr = gl._to_pr(f.mr, f.project, f.commits, f.discussions, f.jobs, f.emoji, f.repo)

      assert(pr.number == 7, 'number = iid')
      assert(pr.state == 'OPEN', ('state normalized, got %q'):format(pr.state))
      assert(pr.isDraft == false, 'isDraft from draft')
      assert(pr.baseRefName == 'main', 'baseRefName = target_branch')
      assert(pr.headRefName == 'feat/widget', 'headRefName = source_branch')
      assert(pr.headRefOid == 'head1', 'headRefOid = diff_refs.head_sha')
      assert(pr.defaultBranch == 'main', 'defaultBranch from project')
      assert(pr.author.login == 'alice', 'author.login')
      assert(pr.commits[1].oid == 'c1', 'commit oid')
      assert(pr.commits[1].messageHeadline == 'first', 'commit headline')
      assert(pr.commits[1].messageBody == 'body here', 'commit body has no leading newline')
      assert(#pr.ci_jobs == 1, 'ci_jobs mapped')
      assert(pr.n_threads == 3, ('n_threads, got %s'):format(pr.n_threads))
      assert(pr.n_resolved == 1, ('n_resolved, got %s'):format(pr.n_resolved))
      assert(vim.tbl_count(pr.reactions) == 2, 'reactions aggregated by name')
      assert(#pr.notes == 1, 'notes = overview comments only')
      assert(pr.notes[1].user == 'erin', 'overview note author')
      assert(next(pr.viewed) == nil, 'viewed is empty (unsupported)')
    end)
  end)

  it('flatten_discussions maps note positions to the shared Comment shape', function()
    n.exec_lua(function()
      local gl = require('guh.provider.gitlab')
      local f = load(FIXTURES)()
      local comments, overview, n_threads, n_resolved = gl._flatten_discussions(f.discussions, f.mr, f.repo)

      assert(#comments == 4, ('expected 4 diff comments, got %d'):format(#comments))
      assert(#overview == 1, 'one overview note')

      local c1 = comments[1]
      assert(c1.id == 1001, 'comment id')
      assert(c1.path == 'a.lua', 'comment path')
      assert(c1.side == 'RIGHT', 'RIGHT-side comment')
      assert(c1.end_line == 5 and c1.start_line == 5, 'line anchor')
      assert(c1.resolved == true, 'resolved flag')
      assert(c1.thread_id == 1001, 'thread_id = first note id')
      assert(c1.thread_node_id == 'disc1', 'thread_node_id = discussion id')
      assert(c1.user.login == 'alice', 'comment author')
      assert(c1.updated_at == '2026-01-02T10:00:00Z', 'updated_at has fractional secs stripped')

      assert(comments[2].in_reply_to_id == 1001, 'reply regroups into its discussion')

      assert(comments[3].side == 'LEFT', 'LEFT-side comment')
      assert(comments[3].end_line == 3, 'LEFT end_line from old_line')
      assert(comments[3].start_line == 2, 'multiline start_line from line_range')

      assert(comments[4].outdated == true, 'stale head_sha -> outdated')
      assert(comments[4].in_head == false, 'stale head_sha -> not in_head')

      assert(n_threads == 3, 'three diff threads')
      assert(n_resolved == 1, 'one resolved thread')
    end)
  end)

  it('to_threads regroups GitLab discussions into threads', function()
    n.exec_lua(function()
      local gl = require('guh.provider.gitlab')
      local f = load(FIXTURES)()
      local comments = gl._flatten_discussions(f.discussions, f.mr, f.repo)
      local threads = require('guh.comments').to_threads(comments)
      local n_threads = 0
      for _, ts in pairs(threads) do
        n_threads = n_threads + #ts
      end
      assert(n_threads == 3, ('expected 3 threads, got %d'):format(n_threads))
      assert(#threads['a.lua'][1].comments == 2, 'thread on a.lua holds root + reply')
    end)
  end)

  it('render_diff anchors a GitLab thread, hiding resolved ones by default', function()
    n.exec_lua(function()
      local gl = require('guh.provider.gitlab')
      local f = load(FIXTURES)()
      local pr = gl._to_pr(f.mr, f.project, f.commits, f.discussions, f.jobs, f.emoji, f.repo)
      local patch = table.concat({
        'diff --git a/a.lua b/a.lua',
        'index 1111111..2222222 100644',
        '--- a/a.lua',
        '+++ b/a.lua',
        '@@ -1,5 +1,5 @@',
        ' one',
        ' two',
        ' three',
        ' four',
        ' five',
        '',
      }, '\n')
      -- disc1 is resolved, so it is hidden unless `dz` (show_resolved) is on.
      local _, hidden = require('guh.comments').render_diff(pr, patch)
      assert(hidden['a.lua'] == nil, 'resolved thread hidden by default')
      pr.show_resolved = true
      local _, shown, n_files = require('guh.comments').render_diff(pr, patch)
      assert(n_files == 1, 'one file in the patch')
      assert(shown['a.lua'] ~= nil, 'thread anchored when resolved threads are shown')
    end)
  end)

  it('get_url derives the web URL from the API web_url (git host != web host)', function()
    n.exec_lua(function()
      local gl = require('guh.provider.gitlab')
      local f = load(FIXTURES)()
      gl._to_pr(f.mr, f.project, f.commits, f.discussions, f.jobs, f.emoji, f.repo)

      local buf = vim.api.nvim_create_buf(false, true)
      local function url(bufstate)
        vim.b[buf].guh = bufstate
        return gl.get_url(buf)
      end
      assert(
        url({ feat = 'pr', repo = f.repo, id = 7 }) == 'https://git.ifoodcorp.com.br/g/s/p/-/merge_requests/7',
        'MR web URL'
      )
      assert(
        url({ feat = 'prdiff', repo = f.repo, id = 7 })
          == 'https://git.ifoodcorp.com.br/g/s/p/-/merge_requests/7/diffs',
        'MR diffs URL'
      )
      assert(url({ feat = 'repo', repo = f.repo, id = 0 }) == 'https://git.ifoodcorp.com.br/g/s/p', 'repo web URL')
      assert(
        url({ feat = 'issue', repo = f.repo, id = 3 }) == 'https://git.ifoodcorp.com.br/g/s/p/-/issues/3',
        'issue web URL'
      )
      assert(url({ feat = 'pr' }) == nil, 'no repo -> nil')
    end)
  end)

  it('builds GitLab argv for the shared call sites', function()
    n.exec_lua(function()
      local gl = require('guh.provider.gitlab')
      local repo = 'g/s/p'
      local function eq(got, want, label)
        assert(vim.deep_equal(got, want), ('%s: got %s'):format(label, vim.inspect(got)))
      end
      eq(gl.pr_diff_cmd(7, repo), { 'glab', 'mr', 'diff', '7', '--raw', '-R', repo }, 'pr_diff_cmd')
      eq(gl.issue_view_cmd(3, repo), { 'glab', 'issue', 'view', '3', '--comments', '-R', repo }, 'issue_view_cmd')
      eq(gl.edit_cmd('issue', 3, repo), { 'glab', 'issue', 'update', '3', '-R', repo }, 'edit_cmd')
      eq(gl.merge_choices(), { 'squash', 'merge', 'rebase' }, 'merge_choices (no --admin)')
    end)
  end)

  it('resolve_thread/note calls are MR-scoped (GitLab needs the MR number)', function()
    n.exec_lua(function()
      local gl = require('guh.provider.gitlab')
      local seen
      local util = require('guh.util')
      local orig = util.system
      util.system = function(cmd)
        seen = cmd
      end
      gl.resolve_thread('disc1', true, 'g/s/p', 7, function() end)
      util.system = orig
      assert(seen, 'no argv recorded')
      local argv = table.concat(seen, ' ')
      assert(argv:find('projects/g%%2Fs%%2Fp/merge_requests/7/discussions/disc1'), ('unexpected argv: %s'):format(argv))
      assert(argv:find('resolved=true', 1, true), ('missing resolved=true: %s'):format(argv))
      assert(argv:find('--hostname', 1, true) == nil, 'no hostname when the repo is unregistered')
    end)
  end)
end)
