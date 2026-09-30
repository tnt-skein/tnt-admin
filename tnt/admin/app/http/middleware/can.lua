--- Права панели: кому что можно — одним списком — и слой `can`, который
--- спрашивает их на входе маршрута.
---
--- Решают ворота `tnt-permissions`, а не признаки личности в обработчиках.
--- Пока правило жило в обработчике, у каждого места отказа было своё
--- условие на признак, и «кому что можно» нельзя было ни прочитать
--- целиком, ни проверить одной проверкой: право, забытое в новом
--- обработчике, не видно ни из одного списка.
---
--- Личность панели своя (`TntAdminIdentity`): признаки `readonly` и `audit`,
--- которые выдаёт приложение. В роли и разрешения ворот её переводят здесь
--- же, настройками ворот `roles_of` и `permissions_of`:
---
---     readonly      → роль observer: cluster.read — смотреть кластер
---     без readonly  → роль admin: cluster.* — ещё действия и конфигурация
---     audit = true  → разрешение audit.read — журнал аудита
---
--- Журнал — отдельным разрешением, а не частью роли `admin`: проверять
--- журнал должен уметь тот, кто не может его подделать, а тот, кто меняет
--- кластер, не обязан читать журнал о себе. Выдаёт его только
--- `audit = true`: право — признак, а не что угодно правдивое, и строка
--- «нет» в личности журнала не открывает.
---
--- Маршрут называет способность слоем (`Module.layer`), а слово отказа
--- у каждой способности своё, из каталога панели: её JS показывает
--- `error.message` как есть, и «у вас нет права менять кластер» оператору
--- понятнее общего слова ворот. Отказ собирает `refuse` панели — тем же
--- видом, что и любой её отказ, и без опознавателя происшествия: нет
--- права — ожидаемый ответ, и искать его в журнале нечего.

local permissions = require('tnt.permissions')

local refusals = require('tnt.admin.app.exceptions.refusal')

local Module = {}

--- Менять кластер: действия, их оценка и правка конфигурации.
Module.CHANGE = 'cluster.change'

--- Смотреть действующую конфигурацию кластера.
---
--- Отдельно от «смотреть кластер»: в конфигурации учётные записи и адреса,
--- и наблюдателю её не показывают. `cluster.read` наблюдателя её
--- не накрывает — звёздочки у него нет.
Module.CONFIG = 'cluster.config.read'

--- Читать журнал аудита и проверять его цепочку.
Module.AUDIT = 'audit.read'

--- Отказ панели на каждую способность, которую спрашивают её маршруты.
---
--- Способность без своего отказа слой не соберёт: общим словом ворот
--- панель не отвечает — его не ждёт её JS.
local REFUSALS = {
    [Module.CHANGE] = 'forbidden_change',
    [Module.CONFIG] = 'forbidden_config',
    [Module.AUDIT] = 'forbidden_audit',
}

--- Роль по признаку `readonly`.
---
--- Личность не таблицей ролей не получает: иначе строка на месте личности
--- прочиталась бы полями строковой библиотеки — без `readonly`, то есть
--- администратором.
---@param identity any
---@return string[]|nil
local function roles_of(identity)
    if type(identity) ~= 'table' then
        return nil
    end

    return { identity.readonly and 'observer' or 'admin' }
end

--- Прямые разрешения по признаку `audit`.
---@param identity any
---@return string[]|nil
local function permissions_of(identity)
    if type(identity) == 'table' and identity.audit == true then
        return { Module.AUDIT }
    end

    return nil
end

--- Ворота панели: роли и перевод личности в них.
---
--- Каталог отказов — панели, а не общий на приложение: ворота объявляют
--- в нём свой отказ при сборке, а в общем каталоге это объявление стало бы
--- чужим кодом у приложения, которому о панели знать нечего.
---@return TntPermissionsGate
function Module.gate()
    local gate = permissions.new({
        errors = refusals.catalog,
        roles_of = roles_of,
        permissions_of = permissions_of,
    })

    return gate:role('observer', { 'cluster.read' }):role('admin', { 'cluster.*' })
end

--- Слой `can`: без способности дальше не пускает.
---
--- Способность без своего отказа — бросок при сборке, на строку того, кто
--- собирает маршрут: опечатка обязана найтись при объявлении, а не
--- на первом запросе оператора.
---@param gate TntPermissionsGate
---@param ability string
---@return table layer Слой для списка `middleware`: функция и имя в журнале
function Module.layer(gate, ability)
    local refusal = REFUSALS[ability]

    if refusal == nil then
        error(('у способности «%s» нет отказа панели'):format(tostring(ability)), 2)
    end

    return {
        function(request, nxt)
            if gate:allows(request.identity, ability) then
                return nxt(request)
            end

            return refusals.refuse(refusal)
        end,
        name = 'can',
    }
end

return Module
