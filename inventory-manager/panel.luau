--!nonstrict
-- panel.luau
-- Inventory management panel

local products = {}
local categories = {}
local allCategories = {}
local categoryInputMode = "new"
local categoryFieldOpen = false
local selectedCategory = "all"
local draftName = ""
local draftCategory = ""
local draftQuantity = ""
local draftKey = 0
local draftError = ""
local showAddForm = false
local hoveredProductId = nil
local editingProductId = nil
local pendingDeleteId = nil
local pendingRepairId = nil
local pendingImport = false

local render

local function resetCategoryMode()
    categoryInputMode = (#allCategories > 0) and "existing" or "new"
    categoryFieldOpen = false
end

-- Color mapping
local COLOR_MAP = {
    black = "#000000",
    preto = "#000000",
    white = "#ffffff",
    branco = "#ffffff",
    ciano = "#00e5ff",
    cyan = "#00e5ff",
    yellow = "#ffea00",
    amarelo = "#ffea00",
    magenta = "#ff00ff",
    purple = "#9c27b0",
    roxo = "#9c27b0",
    red = "#ff0000",
    vermelho = "#ff0000",
    green = "#00ff00",
    verde = "#00ff00",
    blue = "#2979ff",
    azul = "#2979ff",
    orange = "#ff6d00",
    laranja = "#ff6d00",
    pink = "#ff4081",
    rosa = "#ff4081",
    gray = "#9e9e9e",
    cinza = "#9e9e9e"
}

-- ---------------------------------------------------------------------------
-- Helper functions
-- ---------------------------------------------------------------------------

local function getFilteredProducts()
    if selectedCategory == "all" then
        return products
    end
    local filtered = {}
    for _, product in ipairs(products) do
        if (product.category or "Geral") == selectedCategory then
            table.insert(filtered, product)
        end
    end
    return filtered
end

local function getCategoryTotal(categoryName)
    local total = 0
    for _, product in ipairs(products) do
        if (product.category or "Geral") == categoryName then
            total = total + (product.good_quantity or product.quantity or 0)
        end
    end
    return total
end

local function extractColorFromName(name)
    if not name then return nil end
    local lowerName = name:lower()
    for colorName, _ in pairs(COLOR_MAP) do
        if lowerName:find(colorName, 1, true) then
            return colorName
        end
    end
    return nil
end

local function createColorDot(colorName)
    if not colorName then return nil end
    local hexColor = COLOR_MAP[colorName] or "#888888"
    return ui.box({
        fill = hexColor,
        radius = 6,
        width = 12,
        height = 12,
        align = "center",
        justify = "center",
        border = "outline",
        borderWidth = 1
    })
end

-- Quantity capsule
local function createQuantityCapsule(displayQty, badgeColor, badgeTextColor)
    local displayText
    if displayQty == 0 then
        displayText = noctalia.tr("panel.zerado")
    elseif displayQty == 1 then
        displayText = "1 " .. noctalia.tr("panel.unidade")
    else
        displayText = displayQty .. " " .. noctalia.tr("panel.unidades")
    end
    
    return ui.row({
        fill = badgeColor,
        radius = 12,
        paddingH = 10,
        paddingV = 4,
        align = "center",
        justify = "center"
    }, {
        ui.label({
            text = displayText,
            fontSize = 12,
            fontWeight = "bold",
            color = badgeTextColor
        })
    })
end

-- Stock capsule with date and time
local function createStockCapsule(totalProducts)
    local text = (totalProducts == 1) and 
                 string.format(noctalia.tr("panel.stock_singular"), totalProducts) or
                 string.format(noctalia.tr("panel.stock_plural"), totalProducts)
    
    local now = os.time()
    local dateTime = os.date("%d/%m/%Y %H:%M", now)
    
    return ui.row({
        gap = 8,
        align = "center",
        padding = { 2, 0 }
    }, {
        ui.row({
            fill = "#b0ce0a",
            radius = 12,
            paddingH = 12,
            paddingV = 5,
            align = "center",
            justify = "center",
            gap = 4
        }, {
            ui.glyph({ name = "package", size = 13, color = "#1d0101" }),
            ui.label({
                text = text,
                fontSize = 12,
                fontWeight = "bold",
                color = "#000000"
            })
        }),
        ui.row({
            fill = "#616161",
            radius = 12,
            paddingH = 12,
            paddingV = 5,
            align = "center",
            justify = "center",
            gap = 4
        }, {
            ui.glyph({ name = "clock", size = 13, color = "#ffffff" }),
            ui.label({
                text = dateTime,
                fontSize = 12,
                fontWeight = "bold",
                color = "#ffffff"
            })
        })
    })
end

-- Info capsule
local function createInfoCapsule(value, icon, color)
    if not value or value == "" then
        return nil
    end
    return ui.row({
        fill = color,
        radius = 12,
        paddingH = 10,
        paddingV = 4,
        align = "center",
        justify = "center",
        gap = 4
    }, {
        ui.glyph({ name = icon or "info", size = 12, color = "#ffffff" }),
        ui.label({
            text = value,
            fontSize = 11,
            fontWeight = "bold",
            color = "#ffffff"
        })
    })
end

-- ---------------------------------------------------------------------------
-- Export / Import functions
-- ---------------------------------------------------------------------------

local function resolveExportDir()
    local custom = noctalia.string.trim(noctalia.getConfig("export_folder") or "")
    if custom ~= "" then
        if custom:sub(1, 1) == "~" then
            local home = os.getenv("HOME")
            if home then
                custom = home .. custom:sub(2)
            end
        end
        return custom
    end
    return noctalia.pluginDataDir()
end

local function exportStock()
    local productsData = noctalia.state.get("inventory.products") or {}
    if #productsData == 0 then
        noctalia.notify(noctalia.tr("panel.title"), noctalia.tr("panel.no_products"))
        return
    end
    
    local exportData = {
        exported_at = os.date("%d/%m/%Y %H:%M:%S"),
        total_products = #productsData,
        products = productsData
    }
    
    local ok, encoded = pcall(noctalia.json.encode, exportData)
    if not ok or not encoded then
        noctalia.notifyError(noctalia.tr("panel.title"), noctalia.tr("panel.export_error"))
        return
    end
    
    local dir = resolveExportDir()
    if not dir or dir == "" then
        noctalia.notifyError(noctalia.tr("panel.title"), noctalia.tr("panel.export_error"))
        return
    end
    
    local filename = "estoque_" .. os.date("%Y%m%d_%H%M%S") .. ".json"
    local filepath = dir .. "/" .. filename
    
    local writeOk = pcall(noctalia.writeFile, filepath, encoded)
    if writeOk then
        noctalia.notify(noctalia.tr("panel.title"), noctalia.tr("panel.export_success") .. " (" .. filepath .. ")")
    else
        noctalia.notifyError(noctalia.tr("panel.title"), noctalia.tr("panel.export_error"))
    end
end

local function importStock()
    local dir = resolveExportDir()
    if not dir or dir == "" then
        noctalia.notifyError(noctalia.tr("panel.title"), noctalia.tr("panel.import_error"))
        return
    end
    
    local files = noctalia.listDir(dir)
    local jsonFiles = {}
    if files then
        for _, file in ipairs(files) do
            if file:sub(-5) == ".json" and file:sub(1, 7) == "estoque" then
                table.insert(jsonFiles, file)
            end
        end
    end
    
    if #jsonFiles == 0 then
        noctalia.notify(noctalia.tr("panel.title"), noctalia.tr("panel.import_no_files"))
        return
    end
    
    table.sort(jsonFiles, function(a, b) return a > b end)
    local filepath = dir .. "/" .. jsonFiles[1]
    
    local raw = noctalia.readFile(filepath)
    if not raw then
        noctalia.notifyError(noctalia.tr("panel.title"), noctalia.tr("panel.import_error"))
        return
    end
    
    local ok, data = pcall(noctalia.json.decode, raw)
    if not ok or not data or not data.products then
        noctalia.notifyError(noctalia.tr("panel.title"), noctalia.tr("panel.import_error"))
        return
    end
    
    local currentProducts = noctalia.state.get("inventory.products") or {}
    for _, product in ipairs(currentProducts) do
        noctalia.state.set("inventory.cmd", {
            op = "delete",
            id = product.id
        })
    end
    
    noctalia.runAsync("sleep 0.3", function()
        for _, product in ipairs(data.products) do
            noctalia.state.set("inventory.cmd", {
                op = "add",
                name = product.name,
                category = product.category or "Geral",
                quantity = product.quantity or 0
            })
        end
        
        noctalia.notify(noctalia.tr("panel.title"), 
            string.format(noctalia.tr("panel.import_success"), #data.products))
        noctalia.runAsync("sleep 0.3", function()
            render()
        end)
    end)
end

-- ---------------------------------------------------------------------------
-- Action functions
-- ---------------------------------------------------------------------------

local function onDecreaseStock(product)
    if product.good_quantity > 0 then
        noctalia.state.set("inventory.cmd", { 
            op = "adjust", 
            id = product.id, 
            delta = -1,
            type = "good"
        })
        noctalia.runAsync("sleep 0.1", function()
            render()
        end)
    end
end

local function onIncreaseStock(product)
    noctalia.state.set("inventory.cmd", { 
        op = "adjust", 
        id = product.id, 
        delta = 1,
        type = "good"
    })
    noctalia.runAsync("sleep 0.1", function()
        render()
    end)
end

local function onMarkDamage(product)
    local totalQty = product.quantity or 0
    local damageQty = product.damage_quantity or 0
    
    if damageQty < totalQty then
        noctalia.state.set("inventory.cmd", { 
            op = "adjust", 
            id = product.id, 
            delta = 1,
            type = "damage"
        })
        
        noctalia.runAsync("sleep 0.1", function()
            render()
        end)
    else
        noctalia.notify(noctalia.tr("panel.title"), noctalia.tr("panel.all_damaged"))
    end
end

local function onRemoveOneDamage(product)
    local damageQty = product.damage_quantity or 0
    if damageQty > 0 then
        noctalia.state.set("inventory.cmd", { 
            op = "adjust", 
            id = product.id, 
            delta = -1,
            type = "damage"
        })
        
        noctalia.runAsync("sleep 0.1", function()
            render()
        end)
    end
end

local function onRepairAll(product)
    local damageQty = product.damage_quantity or 0
    if damageQty > 0 then
        noctalia.state.set("inventory.cmd", { 
            op = "adjust", 
            id = product.id, 
            delta = -damageQty,
            type = "damage"
        })
        
        noctalia.runAsync("sleep 0.1", function()
            render()
        end)
    end
end

local function confirmDelete(productId)
    noctalia.state.set("inventory.cmd", { 
        op = "delete", 
        id = productId 
    })
    pendingDeleteId = nil
    noctalia.runAsync("sleep 0.1", function()
        render()
    end)
end

local function cancelDelete()
    pendingDeleteId = nil
    render()
end

local function requestDelete(productId)
    pendingDeleteId = productId
    render()
end

-- ---------------------------------------------------------------------------
-- Edit functions
-- ---------------------------------------------------------------------------

local function startEdit(product)
    editingProductId = product.id
    draftName = product.name
    draftCategory = product.category or "Geral"
    draftQuantity = tostring(product.quantity)
    draftError = ""
    draftKey = draftKey + 1
    resetCategoryMode()
    showAddForm = true
    render()
end

local function cancelEdit()
    editingProductId = nil
    draftName = ""
    draftCategory = ""
    draftQuantity = ""
    draftError = ""
    showAddForm = false
    draftKey = draftKey + 1
    render()
end

-- ---------------------------------------------------------------------------
-- Main render
-- ---------------------------------------------------------------------------

render = function()
    local column = {}
    
    -- Store information
    local storeName = noctalia.getConfig("store_name") or ""
    local storeNumber = noctalia.getConfig("store_number") or ""
    local storeCnpj = noctalia.getConfig("store_cnpj") or ""
    local tiName = noctalia.getConfig("ti_name") or ""
    
    -- HEADER
    local headerChildren = {}
    
    -- Row 1: Plugin name + buttons
    local headerRow1 = {}
    
    table.insert(headerRow1, ui.label({
        text = noctalia.tr("panel.title"),
        fontSize = 18,
        fontWeight = "bold",
        color = "on_surface",
        flexGrow = 1
    }))
    
    local headerButtons = {}
    table.insert(headerButtons, ui.button({
        glyph = "plus",
        variant = "outline",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.add_product"),
        border = "outline",
        borderWidth = 1,
        onClick = function()
            if showAddForm then
                cancelEdit()
            else
                editingProductId = nil
                draftName = ""
                draftCategory = ""
                draftQuantity = ""
                draftError = ""
                draftKey = draftKey + 1
                resetCategoryMode()
                showAddForm = true
                render()
            end
        end
    }))
    table.insert(headerButtons, ui.button({
        glyph = "download",
        variant = "outline",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.export"),
        border = "outline",
        borderWidth = 1,
        onClick = function()
            exportStock()
        end
    }))
    table.insert(headerButtons, ui.button({
        glyph = "upload",
        variant = "outline",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.import"),
        border = "outline",
        borderWidth = 1,
        onClick = function()
            pendingImport = true
            render()
        end
    }))
    table.insert(headerButtons, ui.button({
        glyph = "refresh",
        variant = "outline",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.refresh"),
        border = "outline",
        borderWidth = 1,
        onClick = function()
            noctalia.state.set("inventory.cmd", { op = "refresh" })
            render()
        end
    }))
    table.insert(headerButtons, ui.button({
        glyph = "close",
        variant = "outline",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.close"),
        border = "outline",
        borderWidth = 1,
        onClick = function() panel.close() end
    }))
    
    table.insert(headerRow1, ui.row({ gap = 4, align = "center" }, headerButtons))
    table.insert(headerChildren, ui.row({
        align = "center",
        justify = "space_between"
    }, headerRow1))
    
    -- Row 2: Info capsules (IT, Store, Branch, CNPJ) - FIRST
    local infoCapsules = {}
    
    if tiName and tiName ~= "" then
        table.insert(infoCapsules, createInfoCapsule(tiName, "user", "#e65100"))
    end
    
    if storeName and storeName ~= "" then
        table.insert(infoCapsules, createInfoCapsule(storeName, "building-store", "#1976d2"))
    end
    
    if storeNumber and storeNumber ~= "" then
        table.insert(infoCapsules, createInfoCapsule(storeNumber, "note", "#f18304"))
    end
    
    if storeCnpj and storeCnpj ~= "" then
        table.insert(infoCapsules, createInfoCapsule(storeCnpj, "file-text", "#7b1fa2"))
    end
    
    if #infoCapsules > 0 then
        table.insert(headerChildren, ui.row({
            gap = 6,
            align = "center",
            padding = { 4, 0 },
            wrap = true
        }, infoCapsules))
    end
    
    -- Row 3: Stock capsule + date/time - SECOND (after store info)
    local stockCapsule = createStockCapsule(#products)
    if stockCapsule then
        table.insert(headerChildren, ui.row({
            align = "center",
            padding = { 4, 0 }
        }, { stockCapsule }))
    end
    
    -- Categories with manual line wrapping (grouped in rows of 4)
    if #categories > 0 then
        local allCatChildren = {}
        
        -- "All" button
        table.insert(allCatChildren, ui.row({
            fill = selectedCategory == "all" and "primary" or "surface_variant/0.5",
            radius = 12,
            paddingH = 10,
            paddingV = 4,
            align = "center",
            justify = "center",
            onClick = function()
                selectedCategory = "all"
                render()
            end
        }, {
            ui.label({
                text = string.format(noctalia.tr("panel.all") .. " (%d)", #products),
                fontSize = 11,
                fontWeight = "bold",
                color = selectedCategory == "all" and "on_primary" or "on_surface"
            })
        }))
        
        -- Per-category buttons
        for _, cat in ipairs(categories) do
            local total = getCategoryTotal(cat)
            local isSelected = selectedCategory == cat
            table.insert(allCatChildren, ui.row({
                fill = isSelected and "primary" or "surface_variant/0.5",
                radius = 12,
                paddingH = 10,
                paddingV = 4,
                align = "center",
                justify = "center",
                onClick = function()
                    selectedCategory = cat
                    render()
                end
            }, {
                ui.label({
                    text = cat .. " (" .. total .. ")",
                    fontSize = 11,
                    fontWeight = isSelected and "bold" or "regular",
                    color = isSelected and "on_primary" or "on_surface"
                })
            }))
        end
        
        -- Group into rows of 4 (or fewer on the last row)
        local catRows = {}
        local currentRow = {}
        local itemsPerRow = 4
        
        for i, child in ipairs(allCatChildren) do
            table.insert(currentRow, child)
            if i % itemsPerRow == 0 or i == #allCatChildren then
                table.insert(catRows, ui.row({ gap = 4, align = "center" }, currentRow))
                currentRow = {}
            end
        end
        
        if #currentRow > 0 then
            table.insert(catRows, ui.row({ gap = 4, align = "center" }, currentRow))
        end
        
        table.insert(headerChildren, ui.column({
            gap = 4,
            padding = { 4, 6 },
            radius = 6,
            fill = "surface_variant/0.08",
            align = "stretch"
        }, catRows))
    end
    
    table.insert(column, ui.column({ gap = 6, padding = { 0, 0, 8, 0 } }, headerChildren))
    
    -- Import confirmation banner: importing replaces every current product, so
    -- it needs an explicit confirm step instead of running on the first click
    if pendingImport then
        table.insert(column, ui.column({
            gap = 6,
            padding = 10,
            radius = 8,
            fill = "#c62828",
            align = "stretch"
        }, {
            ui.label({
                text = noctalia.tr("panel.import_confirm_message"),
                fontSize = 12,
                fontWeight = "bold",
                color = "#ffffff"
            }),
            ui.row({ gap = 6, justify = "end" }, {
                ui.button({
                    text = noctalia.tr("panel.confirm"),
                    variant = "destructive",
                    controlSize = "sm",
                    onClick = function()
                        pendingImport = false
                        render()
                        importStock()
                    end
                }),
                ui.button({
                    text = noctalia.tr("panel.form.cancel"),
                    variant = "ghost",
                    controlSize = "sm",
                    onClick = function()
                        pendingImport = false
                        render()
                    end
                })
            })
        }))
    end
    
    -- FORM
    if showAddForm then
        local isEditing = editingProductId ~= nil
        local formTitle = isEditing and noctalia.tr("panel.form.edit_title") or noctalia.tr("panel.form.add_title")
        local buttonText = isEditing and noctalia.tr("panel.form.update") or noctalia.tr("panel.form.save")
        
        local formContainer = {}
        
        table.insert(formContainer, ui.label({
            text = formTitle,
            fontSize = 13,
            fontWeight = "bold",
            color = "primary"
        }))
        
        -- Row 1: Name + Quantity + Category controls, all on the same line.
        -- Category: two small buttons ("+" for a brand-new category, list for
        -- picking an existing one) open the corresponding field below instead of
        -- always showing an input/dropdown taking up space. allCategories
        -- includes categories even with zero current stock.
        local row1 = {}
        table.insert(row1, ui.column({ flexGrow = 3, gap = 4 }, {
            ui.label({ text = noctalia.tr("panel.form.name"), fontSize = 11, fontWeight = "bold" }),
            ui.input({
                key = "add-name-" .. draftKey,
                value = draftName,
                placeholder = noctalia.tr("panel.form.name_placeholder"),
                controlSize = "sm",
                onChange = function(value) 
                    draftName = value
                    draftError = ""
                end
            })
        }))
        table.insert(row1, ui.column({ width = 70, gap = 4 }, {
            ui.label({ text = noctalia.tr("panel.form.quantity"), fontSize = 11, fontWeight = "bold" }),
            ui.input({
                key = "add-quantity-" .. draftKey,
                value = draftQuantity,
                placeholder = "0",
                controlSize = "sm",
                onChange = function(value) 
                    draftQuantity = value 
                end
            })
        }))
        
        local categoryButtons = {}
        
        table.insert(categoryButtons, ui.button({
            glyph = "plus",
            variant = (categoryInputMode == "new" and categoryFieldOpen) and "primary" or "outline",
            controlSize = "sm",
            tooltip = noctalia.tr("panel.form.category_mode_new"),
            onClick = function()
                if categoryInputMode == "new" and categoryFieldOpen then
                    categoryFieldOpen = false
                else
                    categoryInputMode = "new"
                    categoryFieldOpen = true
                end
                render()
            end
        }))
        
        if #allCategories > 0 then
            table.insert(categoryButtons, ui.button({
                glyph = "list",
                variant = (categoryInputMode == "existing" and categoryFieldOpen) and "primary" or "outline",
                controlSize = "sm",
                tooltip = noctalia.tr("panel.form.category_mode_existing"),
                onClick = function()
                    if categoryInputMode == "existing" and categoryFieldOpen then
                        categoryFieldOpen = false
                    else
                        categoryInputMode = "existing"
                        categoryFieldOpen = true
                    end
                    render()
                end
            }))
        end
        
        table.insert(row1, ui.column({ width = 90, gap = 4 }, {
            ui.label({ text = noctalia.tr("panel.form.category"), fontSize = 11, fontWeight = "bold" }),
            ui.row({ gap = 6, align = "center" }, categoryButtons)
        }))
        
        table.insert(formContainer, ui.row({ gap = 6 }, row1))
        
        if categoryInputMode == "new" and categoryFieldOpen then
            table.insert(formContainer, ui.input({
                key = "add-category-input-" .. draftKey,
                value = draftCategory,
                placeholder = noctalia.tr("panel.form.category_placeholder"),
                controlSize = "sm",
                onChange = function(value)
                    draftCategory = value
                end
            }))
        elseif categoryInputMode == "existing" and categoryFieldOpen and #allCategories > 0 then
            -- Vertical list: one category per line, so there's no row-width to
            -- overflow regardless of how long a category name is
            local categoryRows = {}
            for _, cat in ipairs(allCategories) do
                table.insert(categoryRows, ui.row({
                    key = "cat-choice-" .. cat,
                    fill = (cat == draftCategory) and "primary" or "surface_variant/0.5",
                    radius = 6,
                    paddingH = 10,
                    paddingV = 5,
                    align = "center",
                    onClick = function()
                        draftCategory = cat
                        categoryFieldOpen = false
                        render()
                    end
                }, {
                    ui.label({
                        text = cat,
                        fontSize = 11,
                        fontWeight = "medium",
                        color = (cat == draftCategory) and "on_primary" or "on_surface"
                    })
                }))
            end
            table.insert(formContainer, ui.column({
                gap = 2,
                padding = 4,
                radius = 8,
                fill = "surface_variant/0.15",
                align = "stretch"
            }, categoryRows))
        end
        
        -- Row 3: Action buttons, right-aligned
        table.insert(formContainer, ui.row({ gap = 4, justify = "end" }, {
            ui.button({
                text = buttonText,
                variant = "primary",
                controlSize = "sm",
                onClick = function()
                    if isEditing then
                        onEditSubmit()
                    else
                        onAddSubmit()
                    end
                end
            }),
            ui.button({
                text = noctalia.tr("panel.form.cancel"),
                variant = "ghost",
                controlSize = "sm",
                onClick = function()
                    cancelEdit()
                end
            })
        }))
        
        if draftError ~= "" then
            table.insert(formContainer, ui.label({ 
                text = draftError, 
                color = "#c62828", 
                fontSize = 11 
            }))
        end
        
        table.insert(column, ui.column({
            gap = 6,
            padding = 8,
            radius = 8,
            fill = "surface_variant/0.35",
            align = "stretch"
        }, formContainer))
    end
    
    -- BODY
    local filteredProducts = getFilteredProducts()
    
    if #filteredProducts == 0 then
        table.insert(column, ui.column({
            gap = 12,
            align = "center",
            padding = 32,
            flexGrow = 1,
            justify = "center"
        }, {
            ui.glyph({ name = "package", size = 48, color = "outline" }),
            ui.label({ 
                text = (selectedCategory ~= "all") and 
                       noctalia.tr("panel.no_category") or 
                       noctalia.tr("panel.no_products"),
                color = "outline", 
                fontSize = 14 
            }),
            ui.button({
                text = noctalia.tr("panel.add_first"),
                variant = "primary",
                onClick = function()
                    editingProductId = nil
                    draftName = ""
                    draftCategory = ""
                    draftQuantity = ""
                    draftKey = draftKey + 1
                    resetCategoryMode()
                    showAddForm = true
                    render()
                end
            })
        }))
    else
        local rows = {}
        for _, product in ipairs(filteredProducts) do
            local goodQty = product.good_quantity or product.quantity or 0
            local damageQty = product.damage_quantity or 0
            local totalQty = product.quantity or 0
            
            local displayQty = goodQty
            
            local lowThreshold = noctalia.getConfig("low_stock_threshold") or 3
            
            local isZero = displayQty == 0
            local isLowStock = displayQty <= lowThreshold and displayQty > 0
            local hasDamage = damageQty > 0
            
            local colorName = extractColorFromName(product.name)
            
            local badgeColor = isZero and "#c62828" or
                              (isLowStock and "#f2b705" or "#2e7d32")
            
            local badgeTextColor = (isLowStock and not isZero) and "#000000" or "#ffffff"
            
            local isHovered = (hoveredProductId == product.id)
            local isPendingDelete = (pendingDeleteId == product.id)
            local isPendingRepair = (pendingRepairId == product.id)
            
            -- Shared hover handler for the whole card: attached to the outer row AND
            -- to every action button inside it, so moving the pointer onto a button
            -- keeps the card "hovered" instead of the button swallowing the event
            -- (buttons are interactive, so they'd otherwise become the hover target
            -- and report "false" to the row while the pointer sits over them).
            local function onCardHover(state)
                if state == "true" then
                    hoveredProductId = product.id
                elseif hoveredProductId == product.id then
                    hoveredProductId = nil
                end
                render()
            end
            
            local productRowChildren = {}
            local mainColumnChildren = {}
            
            local row1Elements = {}
            
            if colorName then
                local dot = createColorDot(colorName)
                if dot then
                    table.insert(row1Elements, dot)
                end
            end
            
            table.insert(row1Elements, ui.label({ 
                text = product.name, 
                fontWeight = (isZero or isLowStock) and "bold" or "regular", 
                fontSize = 13 
            }))
            
            table.insert(row1Elements, createQuantityCapsule(displayQty, badgeColor, badgeTextColor))
            
            if hasDamage then
                table.insert(row1Elements, ui.row({
                    fill = "#c62828",
                    radius = 12,
                    paddingH = 10,
                    paddingV = 4,
                    align = "center",
                    justify = "center"
                }, {
                    ui.label({
                        text = noctalia.tr("panel.avaria_badge") .. " " .. damageQty,
                        fontSize = 12,
                        fontWeight = "bold",
                        color = "#ffffff"
                    })
                }))
            end
            
            table.insert(mainColumnChildren, ui.row({ gap = 6, align = "center" }, row1Elements))
            
            local row2Elements = {}
            table.insert(row2Elements, ui.row({
                border = "outline",
                borderWidth = 1,
                radius = 10,
                paddingH = 8,
                paddingV = 2,
                align = "center",
                justify = "center"
            }, {
                ui.label({ 
                    text = product.category or "Geral",
                    fontSize = 10,
                    color = "on_surface_variant",
                    fontWeight = "medium"
                })
            }))
            
            -- Edit button + action buttons alongside
            local actionsRow = {}
            table.insert(actionsRow, ui.button({
                glyph = "pencil",
                variant = "ghost",
                controlSize = "sm",
                tooltip = noctalia.tr("panel.edit_product"),
                onHover = onCardHover,
                onClick = function()
                    startEdit(product)
                end
            }))
            
            table.insert(actionsRow, ui.button({
                glyph = "minus",
                variant = "ghost",
                controlSize = "sm",
                tooltip = noctalia.tr("panel.decrease"),
                enabled = goodQty > 0,
                onHover = onCardHover,
                onClick = function()
                    onDecreaseStock(product)
                end
            }))
            table.insert(actionsRow, ui.button({
                glyph = "plus",
                variant = "ghost",
                controlSize = "sm",
                tooltip = noctalia.tr("panel.increase"),
                onHover = onCardHover,
                onClick = function()
                    onIncreaseStock(product)
                end
            }))
            table.insert(actionsRow, ui.button({
                glyph = "alert-triangle",
                variant = "ghost",
                controlSize = "sm",
                tooltip = noctalia.tr("panel.damage"),
                enabled = damageQty < totalQty,
                onHover = onCardHover,
                onClick = function()
                    onMarkDamage(product)
                end
            }))
            table.insert(actionsRow, ui.button({
                glyph = "circle-minus",
                variant = "ghost",
                controlSize = "sm",
                tooltip = noctalia.tr("panel.repair_one"),
                enabled = hasDamage,
                onHover = onCardHover,
                onClick = function()
                    onRemoveOneDamage(product)
                end
            }))
            
            if isPendingRepair then
                table.insert(actionsRow, ui.label({
                    text = noctalia.tr("panel.repair_confirm"),
                    fontSize = 10,
                    fontWeight = "bold",
                    color = "#c62828",
                    paddingH = 4
                }))
                table.insert(actionsRow, ui.button({
                    glyph = "check",
                    variant = "destructive",
                    controlSize = "sm",
                    tooltip = noctalia.tr("panel.confirm"),
                    onHover = onCardHover,
                    onClick = function()
                        pendingRepairId = nil
                        render()
                        onRepairAll(product)
                    end
                }))
                table.insert(actionsRow, ui.button({
                    glyph = "close",
                    variant = "ghost",
                    controlSize = "sm",
                    tooltip = noctalia.tr("panel.form.cancel"),
                    onHover = onCardHover,
                    onClick = function()
                        pendingRepairId = nil
                        render()
                    end
                }))
            else
                table.insert(actionsRow, ui.button({
                    glyph = "rotate",
                    variant = "ghost",
                    controlSize = "sm",
                    tooltip = noctalia.tr("panel.repair"),
                    enabled = hasDamage,
                    onHover = onCardHover,
                    onClick = function()
                        pendingRepairId = product.id
                        render()
                    end
                }))
            end
            
            if isPendingDelete then
                table.insert(actionsRow, ui.label({
                    text = noctalia.tr("panel.confirm_delete"),
                    fontSize = 10,
                    fontWeight = "bold",
                    color = "#c62828",
                    paddingH = 4
                }))
                table.insert(actionsRow, ui.button({
                    glyph = "check",
                    variant = "destructive",
                    controlSize = "sm",
                    tooltip = noctalia.tr("panel.confirm"),
                    onHover = onCardHover,
                    onClick = function()
                        confirmDelete(product.id)
                    end
                }))
                table.insert(actionsRow, ui.button({
                    glyph = "close",
                    variant = "ghost",
                    controlSize = "sm",
                    tooltip = noctalia.tr("panel.form.cancel"),
                    onHover = onCardHover,
                    onClick = function()
                        cancelDelete()
                    end
                }))
            else
                table.insert(actionsRow, ui.button({
                    glyph = "trash",
                    variant = "ghost",
                    controlSize = "sm",
                    tooltip = noctalia.tr("panel.delete"),
                    onHover = onCardHover,
                    onClick = function()
                        requestDelete(product.id)
                    end
                }))
            end
            
            table.insert(row2Elements, ui.row({ gap = 4, align = "center" }, actionsRow))
            table.insert(mainColumnChildren, ui.row({ gap = 8, align = "center" }, row2Elements))
            
            table.insert(productRowChildren, ui.column({ flexGrow = 1, gap = 2 }, mainColumnChildren))
            
            table.insert(rows, ui.row({
                key = "product-" .. product.id,
                gap = 8,
                padding = 8,
                radius = 6,
                -- IMPORTANT: never fall back to Lua "nil" here. A table constructor
                -- silently drops any key assigned nil, so the prop would be missing
                -- from the render call instead of explicitly reset - the host then
                -- has nothing telling it to clear the previous value, and the last
                -- fill/border ever applied to this keyed row sticks forever (which is
                -- exactly the "hover gets stuck on every item I've touched" bug).
                -- Always send a real, explicit value on every render instead.
                fill = (isZero or isLowStock) and "surface_variant/0.15" or "on_surface/0",
                border = isHovered and "outline" or "on_surface/0",
                borderWidth = isHovered and 1 or 0,
                align = "center",
                justify = "space_between",
                onHover = onCardHover
            }, productRowChildren))
        end
        table.insert(column, ui.scroll({ gap = 4, flexGrow = 1 }, rows))
    end
    
    panel.render(ui.column({ 
        gap = 8, 
        padding = 8, 
        flexGrow = 1,
        align = "stretch"
    }, column))
end

-- ---------------------------------------------------------------------------
-- Submit functions
-- ---------------------------------------------------------------------------

function onAddSubmit()
    local name = noctalia.string.trim(draftName)
    local category = noctalia.string.trim(draftCategory)
    local quantity = tonumber(draftQuantity) or 0
    
    if name == "" then
        draftError = noctalia.tr("panel.form.name_required")
        showAddForm = true
        render()
        return
    end
    
    noctalia.state.set("inventory.cmd", {
        op = "add",
        name = name,
        category = category,
        quantity = quantity
    })
    
    draftName = ""
    draftCategory = ""
    draftQuantity = ""
    draftError = ""
    showAddForm = false
    draftKey = draftKey + 1
    
    -- Notification is sent by the service once it processes the "add" command,
    -- so it isn't duplicated here
    noctalia.runAsync("sleep 0.2", function()
        render()
    end)
end

function onEditSubmit()
    local name = noctalia.string.trim(draftName)
    local category = noctalia.string.trim(draftCategory)
    local quantity = tonumber(draftQuantity) or 0
    
    if name == "" then
        draftError = noctalia.tr("panel.form.name_required")
        showAddForm = true
        render()
        return
    end
    
    if editingProductId then
        noctalia.state.set("inventory.cmd", {
            op = "update",
            id = editingProductId,
            name = name,
            category = category,
            quantity = quantity
        })
    end
    
    draftName = ""
    draftCategory = ""
    draftQuantity = ""
    draftError = ""
    editingProductId = nil
    showAddForm = false
    draftKey = draftKey + 1
    
    -- Notification is sent by the service once it processes the "update" command,
    -- so it isn't duplicated here
    noctalia.runAsync("sleep 0.2", function()
        render()
    end)
end

-- ---------------------------------------------------------------------------
-- Panel lifecycle
-- ---------------------------------------------------------------------------

function onOpen(_context)
    products = noctalia.state.get("inventory.products") or {}
    
    local catTotals = noctalia.state.get("inventory.category_totals") or {}
    categories = {}
    for _, cat in ipairs(catTotals) do
        table.insert(categories, cat.name)
    end
    table.sort(categories)
    
    allCategories = noctalia.state.get("inventory.all_categories") or {}
    
    selectedCategory = "all"
    showAddForm = false
    editingProductId = nil
    hoveredProductId = nil
    pendingDeleteId = nil
    pendingRepairId = nil
    pendingImport = false
    
    render()
end

function onClose()
    hoveredProductId = nil
    pendingDeleteId = nil
end

noctalia.state.watch("inventory.products", function(value)
    products = (type(value) == "table") and value or {}
    
    local catTotals = noctalia.state.get("inventory.category_totals") or {}
    categories = {}
    for _, cat in ipairs(catTotals) do
        table.insert(categories, cat.name)
    end
    table.sort(categories)
    
    if pendingDeleteId ~= nil then
        local stillExists = false
        for _, p in ipairs(products) do
            if p.id == pendingDeleteId then
                stillExists = true
                break
            end
        end
        if not stillExists then
            pendingDeleteId = nil
        end
    end
    
    render()
end)

noctalia.state.watch("inventory.all_categories", function(value)
    allCategories = (type(value) == "table") and value or {}
    render()
end)
