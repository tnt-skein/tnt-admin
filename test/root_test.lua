--- Тесты корня раскладки: где панель ищет свои страницы и маршруты.
---
--- Каталог находится по самому модулю, а не по рабочему каталогу узла:
--- панель поднимают где угодно, и рядом с ней стоит чужое приложение
--- со своей раскладкой.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.admin.app.support.root')

---@type any
local root

g.before_each(function()
    root = helper.load('tnt.admin.app.support.root')
end)

g.after_each(function()
    helper.unload()
end)

g.test_the_directory_is_the_module_without_its_extension = function()
    -- Где лежит `tnt/admin.lua`, там же лежит и каталог `tnt/admin`:
    -- и в дереве разработки, и в установленном роке.
    root._set_source({
        anchor = function()
            return '/где-то/share/tarantool/tnt/admin.lua'
        end,
    })

    t.assert_equals(root.directory(), '/где-то/share/tarantool/tnt/admin')
end

g.test_a_package_the_loader_does_not_know_is_refused = function()
    -- Панель без своей раскладки бесполезна, и молчать об этом нельзя:
    -- отказ уходит оператору в alerts конфигурации.
    root._set_source({
        anchor = function()
            return nil
        end,
    })

    t.assert_error_msg_contains('пакет tnt.admin не найден загрузчиком', root.directory)
end

g.test_a_path_that_is_not_a_module_is_refused_too = function()
    -- Загрузчик нашёл что-то, что модулем не выглядит: дальше идти
    -- с таким путём некуда.
    root._set_source({
        anchor = function()
            return '/где-то/tnt/admin'
        end,
    })

    t.assert_error_msg_contains('непонятен', root.directory)
end

g.test_the_real_external_asks_the_loader = function()
    -- Умолчание внешней зависимости: каталог ищется `package.search`, —
    -- он знает и `package.path`, и дерево `.rocks`.
    root._set_source(nil)

    t.assert_equals(root.anchor(), package.search(root.ANCHOR))
end
