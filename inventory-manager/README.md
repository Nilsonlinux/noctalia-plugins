# Inventory Manager

Inventory Manager tracks product stock with categories, damaged-unit tracking,
and low-stock alerts. It ships two UI surfaces — a bar widget and a panel —
backed by one headless service that owns the product list, persists it to
disk, and publishes live state that both surfaces read from.

## Plugin

| Field   | Value                                                              |
| ------- | -------------------------------------------------------------------|
| ID      | `nilsonlinux/inventory-manager`                                    |
| Entries | Service: `inventory-service`; bar widget: `inventory-badge`; panel: `inventory-panel` |

## Usage

### Bar Widget

Add the `inventory-badge` bar widget to your bar. It shows a package icon in
the accent color while stock is healthy, and switches to a red icon with a
count badge once any product falls at or below the low-stock threshold.
Hovering shows a tooltip with the current status (no products / all stocked /
`N` product(s) low in stock).

- Left click opens the Inventory Manager panel.
- Right click force-refreshes the published state and shows a brief
  "Refreshing..." notification.

You can also open the panel over IPC:

```sh
noctalia msg panel-toggle nilsonlinux/inventory-manager:inventory-panel
```

### Panel

The panel opens attached to the bar and centered by default. It lists every
product as a card showing its name, a color dot (auto-detected from a color
word in the product name, e.g. "Black", "Vermelho"), the current quantity
capsule, and a damage badge when the product has damaged units. Hovering a
card - including its action buttons - outlines it.

Category tabs above the list ("All" plus one tab per category with stock)
filter the visible cards.

**Adding / editing a product** - the `+` header button (or "Add your first
product" on an empty list) opens the form; the pencil icon on a card opens it
pre-filled for editing. The form has Name, Quantity, and Category on one row,
and Save/Cancel below:

- **Category** has two small buttons instead of a dropdown: `+` opens a plain
  text field for typing a brand-new category, and the list icon (shown only
  once at least one category exists) opens a vertical list of every category
  ever used - including ones with no stock left - so you can pick one instead
  of retyping it. Picking a category closes the list automatically.

**Per-card stock actions**, all with a shared hover outline across the whole
card:

- `-` / `+` - decrease / increase good stock by one.
- Warning triangle - mark one unit as damaged (moves one unit from good to
  damaged stock without changing the total).
- Circle-minus - repair one damaged unit at a time.
- Rotate icon - repair *all* damaged units on the product at once. This asks
  for inline confirmation ("Repair all damaged units?") before running.
- Trash icon - delete the product. This also asks for inline confirmation
  before running.

**Export / Import** - the header's download/upload buttons write and read a
timestamped `estoque_YYYYMMDD_HHMMSS.json` snapshot of the whole product list.
Both use the `export_folder` setting below (falling back to the plugin's data
folder if it's left blank), so exported files stay where import expects them.
Import **replaces every current product** with the file's contents, so it
opens an inline confirmation banner first and only runs after you confirm.

## Settings

### Plugin

| Setting                    | Type   | Default | Description                                                                 |
| --------------------------- | ------ | ------- | ----------------------------------------------------------------------------- |
| `low_stock_threshold`       | `int`  | `3`     | Quantity at or below which a product counts as low stock.                    |
| `enable_low_stock_alerts`   | `bool` | `true`  | Whether low-stock notifications are shown.                                   |
| `store_name`                | `string` | `""`  | Store name shown as a header capsule in the panel.                           |
| `store_number`              | `string` | `""`  | Store/branch number shown as a header capsule in the panel.                  |
| `store_cnpj`                | `string` | `""`  | Store CNPJ shown as a header capsule in the panel.                           |
| `ti_name`                   | `string` | `""`  | Responsible IT technician's name, shown as a header capsule in the panel.    |
| `export_folder`             | `string` | `""`  | Folder used by Export/Import. Accepts `~` for your home folder. Leave blank to use the plugin's default data folder. |

### Bar Widget

| Setting                | Type    | Default     | Description                                              |
| ------------------------ | ------- | ----------- | ----------------------------------------------------------- |
| `glyph`                 | `glyph` | `"package"` | Icon shown on the bar widget.                             |
| `show_low_stock_badge`  | `bool`  | `true`      | Shows or hides the red count badge when stock is low.     |

## Notes

The service also accepts an `add` IPC event with a JSON payload
(`{"name": "...", "category": "...", "quantity": 0}`) to add a product from
outside the panel, e.g. from a shortcut or another plugin.
