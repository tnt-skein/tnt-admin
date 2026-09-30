--- Обзор кластера: узлы, находки и подсказки одним обходом источников.
---
--- Обзор уходит двумя дорогами: ответом `GET /api/v1/overview` и толчком
--- в канал Centrifugo (`tnt.admin.app.services.live`). Собирается он
--- в одном месте и уходит выдачей одной формы (`Overview` из
--- `tnt.admin.app.data.cluster`), чтобы клиент, который сначала спросил,
--- а потом подписался, получал одно и то же тело: две сборки разошлись бы
--- полем при первой же правке одной из них, а канал без формы унёс бы
--- поле, которого нет в описании API.
---
--- Снимок берётся один раз на обзор и передаётся вниз: иначе обзор,
--- которому нужны и узлы, и находки, и подсказки, устроил бы три обхода
--- кластера подряд.

local model = require('tnt.admin.app.domain.cluster')
local views = require('tnt.admin.app.data.cluster')

local Module = {}

---@class TntAdminOverview
---@field cluster TntAdminView Узлы кластера со сводкой по репликасетам
---@field issues table[] Находки диагностики
---@field suggestions table[] Подсказки оператору

--- Собирает представления над источниками, ещё не выданные формой.
---
--- Ответы о части обзора (`GET /api/v1/cluster` и соседи) выдают каждый
--- свою форму и берут отсюда только свою часть. Источника нет — его часть
--- пуста, а не отказ: панель на узле без диагностики показывает пустой
--- кластер.
---@param source TntAdminSource
---@return TntAdminOverview
function Module.collect(source)
    local snapshot = source.snapshot ~= nil and source.snapshot() or nil
    local appointments = source.appointments ~= nil and source.appointments() or nil

    return {
        cluster = model.cluster(snapshot, { appointments = appointments }),
        issues = model.issues(source.issues ~= nil and source.issues() or nil),
        suggestions = model.suggestions(source.suggestions ~= nil and source.suggestions() or nil),
    }
end

--- Обзор целиком, выданный формой: тело ответа и публикации в канале.
---
--- Выдача — таблица с полями записи `Overview`, кодируется она
--- как объявлено: пустой словарь — `{}`, пустой список — `[]`.
---@param source TntAdminSource
---@return table
function Module.of(source)
    return views.Overview.to_table(Module.collect(source))
end

return Module
