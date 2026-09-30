--- Тело отказа панели формой `tnt-data`.
---
--- Тело собирает вид `panel_view` каталога отказов
--- (`tnt.admin.app.exceptions.refusal`), а довески — разбор полей, код
--- ворот, фазу, оценку и отчёт раскатки — дописывает `refuse`. Форма
--- описывает то, что получается, и описание API ставит её телом каждого
--- отказа (`refusal` в `tnt.admin.app.http.openapi`). Согласие формы
--- с видом держит сверка `make lint-api`: образцы отказов идут через
--- панель, и их тела сличаются со схемой — поле, которого форма не знает,
--- и поле формы, которого не принёс ни один образец, одинаково отказ.

local data = require('tnt.data')

local Module = {}

--- Что случилось: код, фраза для человека и данные к ней.
---@class RefusalError
---@field status integer Код ответа ещё раз: тело читают и без строки статуса — в журнале, в письме дежурному
---@field message string Что показать человеку: слово источника либо своё, без чужого текста и стека
---@field incident string|nil Номер записи журнала у происшествия — его называют дежурному
---@field fields table<string, string>|nil Разбор тела или строки запроса: поле — что с ним не так
---@field code string|nil Код ворот, отказавших в действии: по нему видно, какого шага ждут
---@field phase string|nil Фаза, на которой кончилась раскатка правки

---@type TntDataShape<RefusalError>
local RefusalError = data.define({
    name = 'RefusalError',
    about = 'Что случилось: код, фраза для человека и данные к ней',
    fields = {
        {
            'status',
            'integer',
            about = 'Код ответа ещё раз: тело читают и без строки статуса — в журнале, в письме дежурному',
        },
        {
            'message',
            'string',
            about = 'Что показать человеку: слово источника либо своё, без чужого текста и стека',
        },
        {
            'incident',
            'string',
            optional = true,
            about = 'Номер записи журнала у происшествия — его называют дежурному',
        },
        {
            'fields',
            'map',
            of = 'string',
            optional = true,
            about = 'Разбор тела или строки запроса: поле — что с ним не так',
        },
        {
            'code',
            'string',
            optional = true,
            about = 'Код ворот, отказавших в действии: по нему видно, какого шага ждут',
        },
        {
            'phase',
            'string',
            optional = true,
            about = 'Фаза, на которой кончилась раскатка правки',
        },
    },
})

--- Тело любого отказа панели.
---@class Refusal
---@field error RefusalError Что случилось
---@field assessment table<string, any>|nil Оценка, с которой ворота отказали: что изменилось и какое слово ждут
---@field rollout table<string, any>|nil Отчёт незаконченной раскатки: какие узлы правку приняли, а какие отстали

---@type TntDataShape<Refusal>
local Refusal = data.define({
    name = 'Refusal',
    about = 'Тело любого отказа панели: своего, ворот, раскатки, поломки и отказа роутера',
    fields = {
        { 'error', RefusalError, about = 'Что случилось' },
        {
            'assessment',
            'map',
            of = 'any',
            optional = true,
            about = 'Оценка, с которой ворота отказали: что изменилось и какое слово ждут',
        },
        {
            'rollout',
            'map',
            of = 'any',
            optional = true,
            about = 'Отчёт незаконченной раскатки: какие узлы правку приняли, а какие отстали',
        },
    },
})

-- Формы по именам схем, вложенные тоже: их аннотации сверяют проверки
-- пакета, а описание API ссылается на них по имени.
Module.RefusalError = RefusalError
Module.Refusal = Refusal

return Module
