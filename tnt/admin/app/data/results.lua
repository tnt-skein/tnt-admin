--- Что панель передаёт от источников: формы `tnt-data` тел её ответов.
---
--- Оценку действия, итог действия, личность вошедшего и отчёт проверки
--- журнала собирает не панель, а тот, кто их умеет: ворота
--- `tnt.recovery.risk`, действия `tnt.ops`, приложение, журнал
--- `tnt.audit.verify`. Панель отдаёт их как есть и не урезает: поле,
--- которое дописал источник приложения, клиент приложения получит.
--- Поэтому формы здесь открытые (`unknown = 'drop'`) — в схеме нет
--- запрета лишних полей, — а описано в них то, что обещает договор
--- источника по умолчанию.

local data = require('tnt.data')

local Module = {}

--- Лишнее поле источника — не отказ: его приносит приложение.
local OPEN = 'drop'

--- Требование, которое оценка проверила до действия.
---@class Precondition
---@field ok boolean Выполнено ли
---@field label string Что требуется
---@field detail string|nil Почему это важно

---@type TntDataShape<Precondition>
local Precondition = data.define({
    name = 'Precondition',
    about = 'Требование, которое оценка проверила до действия',
    unknown = OPEN,
    fields = {
        { 'ok', 'boolean', about = 'Выполнено ли' },
        { 'label', 'string', about = 'Что требуется' },
        { 'detail', 'string', optional = true, about = 'Почему это важно' },
    },
})

--- Что нужно для подтверждения опасного действия.
---@class Confirmation
---@field required boolean Нужно ли подтверждение
---@field token string|nil Слово, которое оператор присылает confirm_token
---@field acknowledge string|nil Последствия, которые оператор признаёт

---@type TntDataShape<Confirmation>
local Confirmation = data.define({
    name = 'Confirmation',
    about = 'Что нужно для подтверждения опасного действия',
    unknown = OPEN,
    fields = {
        { 'required', 'boolean', about = 'Нужно ли подтверждение' },
        {
            'token',
            'string',
            optional = true,
            about = 'Слово, которое оператор присылает confirm_token',
        },
        {
            'acknowledge',
            'string',
            optional = true,
            about = 'Последствия, которые оператор признаёт',
        },
    },
})

--- Оценка действия до того, как оно сделано.
---@class Assessment
---@field action string Что предлагается сделать
---@field risk string Класс риска: safe, caution либо dangerous
---@field data_loss boolean Могут ли пропасть подтверждённые записи
---@field summary string Что произойдёт, одной строкой
---@field effects string[] Что именно изменится
---@field warnings string[] Чем это грозит
---@field manual string[] Что сделать руками до и вместо
---@field preconditions Precondition[] Что должно быть выполнено
---@field confirm Confirmation Подтверждение
---@field fingerprint string Отпечаток состояния, по которому сделан вывод

---@type TntDataShape<Assessment>
local Assessment = data.define({
    name = 'Assessment',
    about = 'Оценка действия: что случится, чего это стоит и что сделать до',
    unknown = OPEN,
    fields = {
        { 'action', 'string', about = 'Что предлагается сделать' },
        { 'risk', 'string', about = 'Класс риска: safe, caution либо dangerous' },
        {
            'data_loss',
            'boolean',
            about = 'Могут ли пропасть подтверждённые записи',
        },
        { 'summary', 'string', about = 'Что произойдёт, одной строкой' },
        { 'effects', 'list', of = 'string', about = 'Что именно изменится' },
        { 'warnings', 'list', of = 'string', about = 'Чем это грозит' },
        { 'manual', 'list', of = 'string', about = 'Что сделать руками до и вместо' },
        { 'preconditions', 'list', of = Precondition, about = 'Что должно быть выполнено' },
        { 'confirm', Confirmation, about = 'Подтверждение' },
        {
            'fingerprint',
            'string',
            about = 'Отпечаток состояния, по которому сделан вывод',
        },
    },
})

--- Что действие сделало на одном узле.
---@class OutcomeEntry
---@field ok boolean Удалось ли на этом узле
---@field value any|nil Что узел вернул
---@field err string|nil Почему не удалось

---@type TntDataShape<OutcomeEntry>
local OutcomeEntry = data.define({
    name = 'OutcomeEntry',
    about = 'Что действие сделало на одном узле',
    unknown = OPEN,
    fields = {
        { 'ok', 'boolean', about = 'Удалось ли на этом узле' },
        { 'value', 'any', optional = true, about = 'Что узел вернул' },
        { 'err', 'string', optional = true, about = 'Почему не удалось' },
    },
})

--- Чем кончилось действие на узлах.
---@class Outcome
---@field action string Что делали
---@field status string complete — на всех, partial — на части, failed — нигде
---@field entries table<string, OutcomeEntry> Что с каждым узлом, по имени
---@field succeeded string[] Кому удалось
---@field failed string[] Кому нет: по ним и только по ним действие повторяют
---@field summary string Одна строка для человека

---@type TntDataShape<Outcome>
local Outcome = data.define({
    name = 'Outcome',
    about = 'Чем кончилось действие: карта «узел — что с ним» и сводка',
    unknown = OPEN,
    fields = {
        { 'action', 'string', about = 'Что делали' },
        {
            'status',
            'string',
            about = 'complete — на всех, partial — на части, failed — нигде',
        },
        { 'entries', 'map', of = OutcomeEntry, about = 'Что с каждым узлом, по имени' },
        { 'succeeded', 'list', of = 'string', about = 'Кому удалось' },
        {
            'failed',
            'list',
            of = 'string',
            about = 'Кому нет: по ним и только по ним действие повторяют',
        },
        { 'summary', 'string', about = 'Одна строка для человека' },
    },
})

--- Кто вошёл: личность, которую выдала проверка пароля приложения.
---@class Identity
---@field username string|nil Имя оператора
---@field read_only boolean|nil Только смотреть: ни действий, ни конфигурации
---@field audit boolean|nil Читать журнал аудита и проверять его цепочку

---@type TntDataShape<Identity>
local Identity = data.define({
    name = 'Identity',
    about = 'Кто вошёл: личность и её права',
    unknown = OPEN,
    fields = {
        { 'username', 'string', optional = true, about = 'Имя оператора' },
        -- Имя в Lua своё: `readonly` — слово разметки EmmyLua, и строка
        -- аннотации `---@field readonly` анализатор не разбирает. Снаружи
        -- поле зовётся как в личности, `readonly`.
        {
            'read_only',
            'boolean',
            as = 'readonly',
            optional = true,
            about = 'Только смотреть: ни действий, ни конфигурации',
        },
        {
            'audit',
            'boolean',
            optional = true,
            about = 'Читать журнал аудита и проверять его цепочку',
        },
    },
})

--- Откуда продолжить проверку, если кончился бюджет.
---@class AuditCursor
---@field after_id integer Номер последней проверенной записи
---@field hash string|nil Её хеш: с ним сверяется ссылка следующей

---@type TntDataShape<AuditCursor>
local AuditCursor = data.define({
    name = 'AuditCursor',
    about = 'Откуда продолжить проверку: after_id и hash следующего запроса',
    fields = {
        { 'after_id', 'integer', about = 'Номер последней проверенной записи' },
        {
            'hash',
            'string',
            optional = true,
            about = 'Её хеш: с ним сверяется ссылка следующей',
        },
    },
})

--- Отчёт проверки цепочки журнала аудита.
---@class AuditReport
---@field ok boolean Цела ли цепочка на пройденном участке
---@field scanned integer Сколько записей проверено за запрос
---@field seals integer Сколько из них пломб очистки
---@field broken_at integer|nil На какой записи цепочка порвана
---@field reason string|nil Чем порвана
---@field cursor AuditCursor|nil Откуда продолжить: бюджет кончился, а не записи

---@type TntDataShape<AuditReport>
local AuditReport = data.define({
    name = 'AuditReport',
    about = 'Отчёт проверки цепочки журнала аудита',
    unknown = OPEN,
    fields = {
        { 'ok', 'boolean', about = 'Цела ли цепочка на пройденном участке' },
        { 'scanned', 'integer', about = 'Сколько записей проверено за запрос' },
        { 'seals', 'integer', about = 'Сколько из них пломб очистки' },
        {
            'broken_at',
            'integer',
            optional = true,
            about = 'На какой записи цепочка порвана',
        },
        { 'reason', 'string', optional = true, about = 'Чем порвана' },
        {
            'cursor',
            AuditCursor,
            optional = true,
            about = 'Откуда продолжить: бюджет кончился, а не записи',
        },
    },
})

-- Формы по именам схем, вложенные тоже: их аннотации сверяют проверки
-- пакета, а описание API ссылается на них по имени.
Module.Precondition = Precondition
Module.Confirmation = Confirmation
Module.Assessment = Assessment
Module.OutcomeEntry = OutcomeEntry
Module.Outcome = Outcome
Module.Identity = Identity
Module.AuditCursor = AuditCursor
Module.AuditReport = AuditReport

return Module
