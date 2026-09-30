--- Тела запросов API панели формами `tnt-data`.
---
--- Форма — единственное описание тела: из неё обработчик проверяет вход
--- (`Shape.from`), а описание API (`tnt.admin.app.http.openapi`) берёт
--- схему. Поле, дописанное в форму, само попадает и в проверку, и в
--- `docs/api/panel.yaml`, а забытая пересборка описания роняет
--- `make lint-api`.
---
--- Лишние поля выбрасываются, а не отвергаются: за телом стоит браузер,
--- и панель, которой дописали поле, не должна ломаться о старый узел.

local data = require('tnt.data')

local Module = {}

--- Что делать с полем, которого форма не знает.
local UNKNOWN = 'drop'

--- Имя узла или репликасета: пустых имён не бывает, и пустое — опечатка.
local NAME = { 'string', min = 1 }

--- Запрос о действии над узлами: оценка и само действие.
---@class ActionRequest
---@field action string Действие из перечня capabilities
---@field targets string[] Узлы или репликасеты, над которыми его сделать
---@field fingerprint string|nil Отпечаток состояния из оценки, по которой согласились
---@field acknowledge boolean|nil Признание последствий опасного действия
---@field confirm_token string|nil Слово подтверждения из оценки
---@field answers table<string, any>|nil Ответы на требования оценки: что оператор сделал до действия
---@field key string|nil Ключ нажатия: повтор с тем же ключом узел узнаёт и не выполняет дважды

---@type TntDataShape<ActionRequest>
local ActionRequest = data.define({
    name = 'ActionRequest',
    about = 'Действие над узлами: что сделать, где и подтверждение опасного',
    unknown = UNKNOWN,
    fields = {
        { 'action', 'string', min = 1, about = 'Действие из перечня capabilities' },
        {
            'targets',
            'list',
            of = NAME,
            about = 'Узлы или репликасеты, над которыми его сделать',
        },
        {
            'fingerprint',
            'string',
            optional = true,
            about = 'Отпечаток состояния из оценки, по которой согласились',
        },
        {
            'acknowledge',
            'boolean',
            optional = true,
            about = 'Признание последствий опасного действия',
        },
        {
            'confirm_token',
            'string',
            optional = true,
            about = 'Слово подтверждения из оценки',
        },
        {
            'answers',
            'map',
            of = 'any',
            optional = true,
            about = 'Ответы на требования оценки: что оператор сделал до действия',
        },
        {
            'key',
            'string',
            optional = true,
            about = 'Ключ нажатия: повтор с тем же ключом узел узнаёт и не выполняет дважды',
        },
    },
})

Module.ActionRequest = ActionRequest

--- Запрос о правке конфигурации кластера.
---@class RolloutRequest
---@field text string Новая конфигурация кластера текстом YAML
---@field removing string[]|nil Узлы, которые правка выводит из состава: вычеркнуть узел и вывести его — разные вещи

---@type TntDataShape<RolloutRequest>
local RolloutRequest = data.define({
    name = 'RolloutRequest',
    about = 'Правка конфигурации кластера',
    unknown = UNKNOWN,
    fields = {
        {
            'text',
            'string',
            min = 1,
            about = 'Новая конфигурация кластера текстом YAML',
        },
        {
            'removing',
            'list',
            of = NAME,
            optional = true,
            about = 'Узлы, которые правка выводит из состава: вычеркнуть узел и вывести его — разные вещи',
        },
    },
})

Module.RolloutRequest = RolloutRequest

--- Запрос о входе по имени и паролю.
---
--- Пароль скрытый: его принимают, но не отдают, и отказ его значения
--- не показывает.
---@class LoginRequest
---@field username string Имя оператора
---@field password string Пароль оператора

---@type TntDataShape<LoginRequest>
local LoginRequest = data.define({
    name = 'LoginRequest',
    about = 'Имя и пароль оператора',
    unknown = UNKNOWN,
    fields = {
        { 'username', 'string', min = 1, about = 'Имя оператора' },
        { 'password', 'string', hidden = true, about = 'Пароль оператора' },
    },
})

Module.LoginRequest = LoginRequest

return Module
