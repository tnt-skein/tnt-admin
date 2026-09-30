--- Тесты подключения пакета по имени: панель питается тем, что стоит рядом.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.admin.app.support.packages')

---@type any
local packages

g.before_each(function()
    packages = helper.load('tnt.admin.app.support.packages')
end)

g.after_each(function()
    helper.unload()
end)

g.test_an_installed_package_is_taken_by_name = function()
    local placed = {}
    local previous = package.loaded['tnt.воображаемый']

    package.loaded['tnt.воображаемый'] = placed

    local taken = packages.of('tnt.воображаемый')

    package.loaded['tnt.воображаемый'] = previous

    t.assert_is(taken, placed)
end

g.test_a_package_that_is_not_installed_is_empty = function()
    -- Пустота, а не бросок: развёртывание без диагностики или без
    -- действий — обычное дело, а не поломка узла.
    t.assert_equals(packages.of('tnt.нет.такого'), nil)
end
