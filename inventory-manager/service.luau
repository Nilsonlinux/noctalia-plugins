--!nonstrict
-- service.luau
-- Headless service

local products = {}
local dataPath = nil

local function trim(s)
    return noctalia.string.trim(s or "")
end

local function generateId()
    return "p" .. tostring(os.time()) .. string.format("%03d", math.floor((os.clock() * 1000) % 1000))
end

local function loadState()
    local dir = noctalia.pluginDataDir()
    if dir == nil then
        return
    end
    dataPath = dir .. "/state.json"

    local raw = noctalia.readFile(dataPath)
    if raw ~= nil then
        local ok, decoded = pcall(noctalia.json.decode, raw)
        if ok and type(decoded) == "table" and type(decoded.products) == "table" then
            products = decoded.products
            for _, p in ipairs(products) do
                if not p.damage_quantity then
                    p.damage_quantity = 0
                end
            end
        else
            products = {}
        end
    else
        products = {}
    end
end

local function saveState()
    if dataPath == nil then
        return false
    end
    local ok, encoded = pcall(noctalia.json.encode, { products = products })
    if ok and type(encoded) == "string" then
        local writeOk = pcall(noctalia.writeFile, dataPath, encoded)
        return writeOk and true or false
    end
    return false
end

local function publishState()
    local statuses = {}
    local lowStockCount = 0
    local damageCount = 0
    local threshold = noctalia.getConfig("low_stock_threshold") or 3
    local categoryTotals = {}
    local allCategoriesSet = {}
    
    for _, product in ipairs(products) do
        local cat = product.category or "Geral"
        allCategoriesSet[cat] = true
        
        local goodQuantity = product.quantity - (product.damage_quantity or 0)
        
        if goodQuantity > 0 then
            categoryTotals[cat] = (categoryTotals[cat] or 0) + goodQuantity
        end
        
        if (product.damage_quantity or 0) > 0 then
            damageCount = damageCount + 1
        end
        
        if goodQuantity <= threshold and goodQuantity > 0 then
            lowStockCount = lowStockCount + 1
        end
        
        table.insert(statuses, {
            id = product.id,
            name = product.name,
            category = cat,
            quantity = product.quantity,
            damage_quantity = product.damage_quantity or 0,
            good_quantity = product.quantity - (product.damage_quantity or 0)
        })
    end
    
    local categoryList = {}
    for cat, total in pairs(categoryTotals) do
        if total > 0 then
            table.insert(categoryList, {
                name = cat,
                total = total
            })
        end
    end
    table.sort(categoryList, function(a, b) return a.name < b.name end)
    
    -- Every category that has ever been used on a product, regardless of current
    -- stock level - used by the panel's "existing category" picker so a category
    -- doesn't disappear from it just because its products are all at zero
    local allCategories = {}
    for cat, _ in pairs(allCategoriesSet) do
        table.insert(allCategories, cat)
    end
    table.sort(allCategories)
    
    noctalia.state.set("inventory.products", statuses)
    noctalia.state.set("inventory.total", #products)
    noctalia.state.set("inventory.low_stock_count", lowStockCount)
    noctalia.state.set("inventory.damage_count", damageCount)
    noctalia.state.set("inventory.category_totals", categoryList)
    noctalia.state.set("inventory.all_categories", allCategories)
end

-- Process commands from the panel
noctalia.state.watch("inventory.cmd", function(cmd)
    if type(cmd) ~= "table" then
        return
    end
    
    local op = cmd.op or "unknown"
    
    if op == "add" then
        local name = trim(cmd.name or "")
        local category = trim(cmd.category or "Geral")
        local quantity = tonumber(cmd.quantity) or 0
        
        if name ~= "" then
            local product = {
                id = generateId(),
                name = name,
                category = category,
                quantity = quantity,
                damage_quantity = 0
            }
            
            table.insert(products, product)
            saveState()
            publishState()
            noctalia.notify(noctalia.tr("panel.title"), noctalia.tr("panel.added") .. ": " .. name)
        end
    
    elseif op == "update" then
        local id = cmd.id
        local name = trim(cmd.name or "")
        local category = trim(cmd.category or "Geral")
        local quantity = tonumber(cmd.quantity) or 0
        
        if name == "" then
            return
        end
        
        local found = false
        for _, product in ipairs(products) do
            if product.id == id then
                product.name = name
                product.category = category
                product.quantity = quantity
                found = true
                break
            end
        end
        
        if found then
            saveState()
            publishState()
            noctalia.notify(noctalia.tr("panel.title"), noctalia.tr("panel.updated") .. ": " .. name)
        end
    
    elseif op == "adjust" then
        local id = cmd.id
        local delta = tonumber(cmd.delta) or 0
        local kind = cmd.type or "good"
        
        local found = false
        for _, product in ipairs(products) do
            if product.id == id then
                if kind == "good" then
                    local newQuantity = product.quantity + delta
                    if newQuantity < 0 then
                        noctalia.notifyError(noctalia.tr("panel.title"), noctalia.tr("panel.error_negative"))
                        return
                    end
                    product.quantity = newQuantity
                elseif kind == "damage" then
                    local newDamage = (product.damage_quantity or 0) + delta
                    if newDamage < 0 then
                        noctalia.notifyError(noctalia.tr("panel.title"), noctalia.tr("panel.error_negative"))
                        return
                    end
                    product.damage_quantity = newDamage
                end
                found = true
                break
            end
        end
        
        if found then
            saveState()
            publishState()
        end
    
    elseif op == "delete" then
        local id = cmd.id
        
        local found = false
        for i, product in ipairs(products) do
            if product.id == id then
                table.remove(products, i)
                found = true
                break
            end
        end
        
        if found then
            saveState()
            publishState()
        end
    
    elseif op == "refresh" then
        publishState()
    end
    
    noctalia.state.set("inventory.cmd", nil)
end)

-- Lifecycle
loadState()
publishState()
noctalia.setUpdateInterval(60000)

function update()
    publishState()
end

function onConfigChanged()
    publishState()
end

function onIpc(event, payload)
    if event == "refresh" then
        publishState()
    elseif event == "add" and payload then
        local data = noctalia.json.decode(payload)
        if data then
            local name = trim(data.name or "")
            local category = trim(data.category or "Geral")
            local quantity = tonumber(data.quantity) or 0
            
            if name ~= "" then
                local product = {
                    id = generateId(),
                    name = name,
                    category = category,
                    quantity = quantity,
                    damage_quantity = 0
                }
                table.insert(products, product)
                saveState()
                publishState()
                noctalia.notify(noctalia.tr("panel.title"), noctalia.tr("panel.added") .. ": " .. name)
            end
        end
    end
end

function onExit()
    saveState()
end
