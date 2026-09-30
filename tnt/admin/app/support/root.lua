--- Корень раскладки панели: где лежит пакет.
---
--- Панель — приложение фреймворка, но живёт оно не в каталоге узла,
--- а внутри рока: страницы, маршруты и всё остальное едут вместе с кодом.
--- Поэтому корень раскладки находится по самому модулю — где лежит
--- `tnt/admin.lua`, там же лежит и каталог `tnt/admin`, — и в дереве
--- разработки, и в установленном роке. Гадать про рабочий каталог узла
--- нельзя: панель поднимают где угодно, и рядом с ней стоит чужое
--- приложение со своей раскладкой.

local external = require('tnt.external')

--- Отказ без места вызова: текст уходит оператору в alerts конфигурации.
local fail = require('tnt.must.fail').raise

local Module = {}

--- Имя модуля, по которому ищется каталог пакета. Оно же — приставка
--- имён модулей раскладки: `tnt.admin.routes.api`.
Module.ANCHOR = 'tnt.admin'

--- Где лежит модуль пакета: путь к `tnt/admin.lua`.
---
--- `package.search` — расширение Tarantool: оно знает и `package.path`,
--- и дерево `.rocks`, то есть находит пакет и в дереве разработки,
--- и установленным.
---@return string|nil
function Module.anchor()
    return package.search(Module.ANCHOR)
end

--- Средства снаружи: поиск модуля.
local source = external.install(Module, { anchor = Module.anchor })

--- Каталог раскладки пакета: `<где-то>/tnt/admin`.
---@return string
function Module.directory()
    local anchor = source().anchor()

    if anchor == nil then
        fail(
            ('пакет %s не найден загрузчиком: раскладку панели негде взять'):format(
                Module.ANCHOR
            )
        )
    end

    ---@cast anchor string
    local path = anchor:match('^(.*)%.lua$')

    if path == nil then
        fail(
            ('путь пакета «%s» непонятен: раскладку панели негде взять'):format(
                anchor
            )
        )
    end

    return path
end

return Module
