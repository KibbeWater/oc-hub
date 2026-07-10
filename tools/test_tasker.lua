-- Desktop tests for hive/core/tasker.lua (Lua 5.3+):
--   lua tools/test_tasker.lua
-- Covers decomposition (scan_area, mine_region), pull-triggered assignment with
-- capability + energy vetoes, lease expiry / requeue / max-attempts, recurring
-- tasks, parent completion, and snapshot+journal crash recovery.

package.path = "hive/core/?.lua;tools/?.lua;" .. package.path
local store = require("store")
local tasker = require("tasker")
local hivesim = require("hivesim")

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("OK   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (" -- " .. tostring(detail)) or ""))
  end
end

-- controllable clock
local clock = 0
local function now() return clock end

local function newTasker(fs)
  local st = store.new{ fs = fs or hivesim.memfs() }
  return tasker.new{ store = st, dir = "/var/hive", now = now, lease = 90 }, st
end

-- decomposition -----------------------------------------------------------

do
  local tk = newTasker()
  local leaves = tk.submit{ type = "scan_area", params = { x1 = 0, z1 = 0, x2 = 31, z2 = 15 } }
  -- x 0..31 -> tiles cx 0,1 ; z 0..15 -> tile cz 0  => 2 tiles
  check("scan_area -> 2 scan_tile", #leaves == 2, #leaves)
  check("scan_tile carries needs", leaves[1].needs[1] == "scan")
  check("scan_tile startPos centered", leaves[1].startPos.x % 16 == 8)

  local tk2 = newTasker()
  local slabs = tk2.submit{ type = "mine_region",
    params = { x1 = 0, y1 = 60, z1 = 0, x2 = 31, y2 = 65, z2 = 15 } }
  -- footprint 32x16 -> 2x1 = 2 columns of slabs; height 60..65 (6) -> 2 slabs of 3
  check("mine_region -> 4 slabs", #slabs == 4, #slabs)
  local topFirst = true
  for _, s in ipairs(slabs) do
    if s.params.y2 ~= 65 and s.params.y2 ~= 62 then topFirst = false end
  end
  check("slabs are 3-high top-down", topFirst)
  check("slabs carry parity for checkerboard", slabs[1].params.parity ~= nil)
end

-- assignment: capability + scoring + energy veto --------------------------

do
  local tk = newTasker()
  tk.submit{ type = "scan_tile", needs = { "scan" }, priority = 5,
    startPos = { x = 100, y = 128, z = 0 } }
  tk.submit{ type = "mine_slab", needs = { "mine" }, priority = 5,
    startPos = { x = 0, y = 60, z = 0 } }

  local drone = { id = "d1", caps = { "scan" }, pos = { x = 0, y = 128, z = 0 }, energy = 1 }
  local t = tk.assignTo(drone)
  check("drone gets scan task only", t and t.type == "scan_tile", t and t.type)
  check("assigned task has assignee + lease", t.assignee == "d1" and t.lease == now() + 90)

  -- second assign for the same drone finds nothing left it can do
  check("no second scan task", tk.assignTo(drone) == nil)

  local robot = { id = "r1", caps = { "mine", "scan" }, pos = { x = 0, y = 60, z = 0 } }
  local t2 = tk.assignTo(robot)
  check("robot gets mine task", t2 and t2.type == "mine_slab", t2 and t2.type)

  -- energy estimator can veto
  local tk2 = newTasker()
  tk2.submit{ type = "goto", needs = {}, startPos = { x = 0, y = 64, z = 0 } }
  local vetoed = tk2.assignTo({ id = "d2", caps = {}, pos = { x = 0, y = 64, z = 0 } },
    function() return nil end)
  check("energy estimator vetoes", vetoed == nil)
end

-- scoring prefers higher priority then nearer -----------------------------

do
  local tk = newTasker()
  tk.submit{ type = "goto", needs = {}, priority = 3, startPos = { x = 10, y = 64, z = 0 } }
  tk.submit{ type = "goto", needs = {}, priority = 8, startPos = { x = 500, y = 64, z = 0 } }
  local dev = { id = "d", caps = {}, pos = { x = 0, y = 64, z = 0 } }
  local t = tk.assignTo(dev)
  check("higher priority wins over distance", t.priority == 8, t.priority)
end

-- lease expiry -> requeue -> max attempts -> failed ------------------------

do
  local tk = newTasker()
  tk.submit{ type = "goto", needs = {}, startPos = { x = 0, y = 64, z = 0 } }
  local dev = { id = "d", caps = {}, pos = { x = 0, y = 64, z = 0 } }

  local t = tk.assignTo(dev)
  local id = t.id
  clock = clock + 100 -- past the 90s lease
  tk.sweep()
  check("expired lease requeues", tk.get(id).state == "queued" and tk.get(id).attempts == 1,
    tk.get(id).state)

  -- burn the remaining attempts
  for _ = 1, 2 do
    tk.assignTo(dev)
    clock = clock + 100
    tk.sweep()
  end
  check("task fails after max attempts", tk.get(id).state == "failed", tk.get(id).state)
end

-- report renews lease and flips assigned->active --------------------------

do
  clock = 1000
  local tk = newTasker()
  tk.submit{ type = "goto", needs = {}, startPos = { x = 0, y = 64, z = 0 } }
  local dev = { id = "d", caps = {}, pos = { x = 0, y = 64, z = 0 } }
  local t = tk.assignTo(dev)
  clock = clock + 60
  tk.report(t.id, { pct = 0.5, note = "halfway" })
  check("report flips to active", tk.get(t.id).state == "active")
  check("report renews lease", tk.get(t.id).lease == now() + 90)
  clock = clock + 60 -- 120s since assign, but lease was renewed at +60
  tk.sweep()
  check("renewed lease survives sweep", tk.get(t.id).state == "active")
end

-- onLost requeues a device's work -----------------------------------------

do
  local tk = newTasker()
  tk.submit{ type = "goto", needs = {}, startPos = { x = 0, y = 64, z = 0 } }
  local dev = { id = "gone", caps = {}, pos = { x = 0, y = 64, z = 0 } }
  local t = tk.assignTo(dev)
  tk.onLost("gone")
  check("onLost requeues", tk.get(t.id).state == "queued" and tk.get(t.id).assignee == nil)
end

-- recurring task re-queues on completion ----------------------------------

do
  clock = 5000
  local tk = newTasker()
  local created = tk.submit{ type = "farm_pass", needs = { "farm" },
    startPos = { x = 0, y = 64, z = 0 }, recur = { every = 1800 } }
  tk.complete(created[1].id, "ok")
  local farmTasks = tk.byState("queued")
  check("recurring task re-queued a fresh instance", #farmTasks == 1, #farmTasks)
  check("re-queued instance keeps recur", farmTasks[1].recur and farmTasks[1].recur.every == 1800)
end

-- parent completes when all children done ---------------------------------

do
  local tk = newTasker()
  local leaves, parentId = tk.submit{ type = "scan_area",
    params = { x1 = 0, z1 = 0, x2 = 31, z2 = 15 } }
  check("parent created for multi-leaf", parentId ~= nil)
  tk.complete(leaves[1].id, "ok")
  check("parent still active after 1/2", tk.get(parentId).state ~= "done")
  tk.complete(leaves[2].id, "ok")
  check("parent done after all children", tk.get(parentId).state == "done")
end

-- crash recovery: snapshot + journal replay -------------------------------

do
  local fs = hivesim.memfs()
  clock = 200
  local tk = newTasker(fs)
  local created = tk.submit{ type = "scan_area", params = { x1 = 0, z1 = 0, x2 = 47, z2 = 15 } }
  local dev = { id = "d", caps = { "scan" }, pos = { x = 0, y = 128, z = 0 } }
  local a = tk.assignTo(dev)
  tk.report(a.id, { pct = 0.3 })
  tk.complete(created[1].id, "done")
  local doneId = created[1].id
  local activeId = a.id

  -- simulate a crash+reboot: brand-new tasker on the same store, load state.
  local tk2 = newTasker(fs)
  tk2.load()
  check("done task recovered", tk2.get(doneId) and tk2.get(doneId).state == "done",
    tk2.get(doneId) and tk2.get(doneId).state)
  -- the active/assigned task should have reverted to queued on recovery
  check("in-flight task requeued on recovery",
    tk2.get(activeId) and tk2.get(activeId).state == "queued", tk2.get(activeId) and tk2.get(activeId).state)
  -- counter preserved so new ids don't collide
  local before = tk2.counter()
  tk2.submit{ type = "goto", needs = {}, startPos = { x = 0, y = 64, z = 0 } }
  check("id counter preserved across recovery", tk2.counter() == before + 1)

  -- checkpoint folds journal into snapshot and truncates
  tk2.checkpoint()
  check("checkpoint truncates journal", tk2.journalSize() == 0, tk2.journalSize())
  local tk3 = newTasker(fs)
  tk3.load()
  check("state survives checkpoint", tk3.get(doneId).state == "done")
end

print(string.rep("-", 40))
if failures == 0 then
  print("all tasker tests passed")
  os.exit(0)
else
  print(failures .. " test(s) failed")
  os.exit(1)
end
