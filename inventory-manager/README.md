Inventory Manager

Inventory Manager is a powerful and intuitive plugin for Noctalia that helps you manage your product inventory directly from your desktop panel.

https://img.shields.io/badge/Noctalia-Plugin-blue
https://img.shields.io/badge/License-MIT-yellow.svg
https://img.shields.io/badge/Version-1.0.0-green
✨ Features
📊 Product Management

    Add Products - Create new products with name, category, and quantity

    Edit Products - Modify existing product details

    Delete Products - Remove products with confirmation dialog

    Stock Adjustment - Increase or decrease stock with +/- buttons

    Damage System - Mark products as damaged with a dedicated counter

    Repair System - Move damaged items back to good stock

🏷️ Categories

    Automatic Category Management - Categories are created automatically when you add products

    Category Filtering - Filter products by category with clickable pills

    Category Totals - See total items per category at a glance

    Smart Layout - Categories wrap to multiple lines when there are many

🎨 Visual Interface

    Color-Coded Stock Levels

        🟢 Green: Stock above threshold

        🟡 Yellow: Low stock (≤ threshold)

        🔴 Red: Zero stock

        🔴 Red Badge: Damaged items count

    Store Information Display

        Store Name

        Store/Branch Number

        CNPJ (Brazilian company registration)

        IT Technician Name

    Real-time Clock - Shows last update timestamp

    Hover Effects - Visual feedback when hovering over products

💾 Data Management

    Export Stock - Export all products to JSON file

    Import Stock - Restore products from exported JSON file

    Persistent Storage - Data saved automatically between sessions

🌐 Internationalization

    Portuguese (pt-BR) - Full translation

    English (en) - Full translation

    Easy to add more languages

📸 Screenshots
Main Panel
text

📦 Inventory Manager                    [➕] [📥] [📤] [🔄] [✕]

[👤 Nilson] [🏢 Novo Atacarejo] [📝 055] [📄 20.300.157/0068-57]

[📦 Stock (9 products)] [🕐 29/08/2026 07:58]

[Todos (9)] [Frente de Loja (PDV) (5)] [Infraestrutura (TI) (0)]
[Operação (Loja) (0)] [Retaguarda (Adm) (0)]

Bolsa de Tinta EPSON M5899/C8100 Black    3 Units    Suprimentos    ✏️ ➖ ➕ ⚠️ ⟳ 🗑️
Caixa de Manutenção WF-M5899              Zeroed     Suprimentos    ✏️ ➖ ➕ ⚠️ ⟳ 🗑️

Add Product Form
text

Adicionar Produto
Nome: [____________________]  Categoria: [________________] [▼]
Quantidade: [0]  [Save] [Cancel]

🚀 Installation
Automatic (Recommended)

    Open Noctalia Settings → Plugins

    Search for "Inventory Manager"

    Click Install

Manual
bash

# Clone the repository
git clone https://github.com/nilsonlinux/inventory-manager.git

# Copy to Noctalia plugins directory
cp -r inventory-manager ~/.local/share/noctalia/plugins/

# Restart Noctalia or reload plugins

🔧 Configuration
Plugin Settings
Setting	Description	Default
Low Stock Threshold	Quantity below which stock is considered low	3
Enable Low Stock Alerts	Show notifications for low stock products	true
Store Name	Name of the store to display in the panel	""
Store/Branch Number	Store identifier number	""
CNPJ	Brazilian company registration number	""
IT Name	Name of the responsible IT technician	""
Widget Settings
Setting	Description	Default
Icon	Bar widget icon	package
Show Low Stock Badge	Display red badge with low stock count	true
🎮 Usage Guide
Opening the Panel

    Left-click the widget in the bar to open the inventory panel

Adding a Product

    Click the ➕ button in the top-right corner

    Fill in the product details:

        Name (required)

        Category (type or select from dropdown)

        Quantity (optional, defaults to 0)

    Click "Save"

Editing a Product

    Click the ✏️ (pencil) icon next to the product

    Update any fields

    Click "Update"

Adjusting Stock

    Use the ➕ button to increase stock by 1

    Use the ➖ button to decrease stock by 1

Marking as Damaged

    Click the ⚠️ button to move one unit from good stock to damaged stock

    Damaged items are tracked separately and shown in a red badge

Repairing Damaged Items

    Click the ⟳ button to move all damaged items back to good stock

Deleting a Product

    Click the 🗑️ (trash) icon

    Confirm deletion by clicking the ✓ button

    Cancel deletion by clicking the ✕ button

Filtering by Category

    Click on any category pill to filter products

    Click "All" to show all products

Exporting Stock

    Click the 📥 (download) button

    A JSON file will be saved to the plugin's data directory

Importing Stock

    Click the 📤 (upload) button

    The latest exported file will be imported automatically

📁 File Structure
text

inventory-manager/
├── plugin.toml              # Plugin manifest and settings
├── service.luau             # Background service (data management)
├── widget.luau              # Bar widget
├── panel.luau               # Main inventory panel
├── translations/
│   ├── en.json              # English translations
│   └── pt-BR.json           # Portuguese translations
└── README.md               # This file