--- Пакет по имени: не установлен — пусто.
---
--- Панель питается тем, что стоит рядом, и спрашивает об этом одинаково
--- во всех своих службах: источники, обход кластера, действия. Пустота,
--- а не бросок: развёртывание без диагностики или без действий — обычное
--- дело, а не поломка узла.

local Module = {}

--- Подключает пакет по имени.
---@param name string Имя модуля, например tnt.cluster
---@return table|nil
function Module.of(name)
    local ok, package = pcall(require, name)

    if not ok then
        return nil
    end

    ---@cast package table
    return package
end

return Module
