# ArcheRage farm timers: research notes

Researched 2026-10-17. Dataset: `farm_items.json` (288 entries).

## How the data was collected
1. **ArcheRage Wiki DB** (`wiki.archerage.to/na-en/db`). This is ArcheRage's own database. I scraped the full lists
   `items/plants` (294 seeds and saplings) and `items/animals` (109 livestock entries), then every item page (tooltip text:
   "Matures in", "Harvest/Milk/Shear/Pluck every", "Climate", harvest-count limits, disappear/die text). I also scraped all 490 linked
   object ("doodad") pages, which give an exact `Growth time` to the minute plus the object's climate.
   - When the tooltip and the object agree within 6%, I used the object value (it is more precise; e.g. Oak shows 2 d 1 h on the tooltip and 2 d 0 h 35 m on the object).
   - When they disagree, I used the tooltip value and wrote `DISCREPANCY` in `notes` (13 items, listed below).
2. **ArcheRage official forums** (na.archerage.to / ru.archerage.to): server rates and farming patch notes.
3. **Official-ArcheAge sources** (archeage.fandom.com, Reddit r/archeage, saarith.com, gameskinny, tentonhammer, a 2014 blogspot guide, a Russian guide on helpiks.org).
   I used these only for mechanics (climate %, watering %, wither and death behaviour) and to cross-check base values.

## THE KEY ArcheRage FACT: growth runs 2x faster
- On the ArcheRage "Server Features" thread, staff write: *"We accelerated the growth of all objects in the game (from trees to cattle) – 2 times!"*
  The unofficial FAQ (thread 937) says the same: "Growth time halved".
  Sources: https://na.archerage.to/forums/threads/server-features.9254/ and https://na.archerage.to/forums/threads/guide-faq-unofficial.937/
- **The ArcheRage wiki and the in-game tooltips show the UNHALVED vanilla times.** In thread 5310 (Mar 2018) staff confirmed that the tooltip value
  (Impatiens, 1d8h) is the vanilla timer and that the server halves it: "cut timer in half as on the rest we had in 2.9". They then halved Pineapple, Pansy, Amaranth,
  Hibiscus (both kinds), Watermelon and Impatiens (seeds and bundles), plus Worm Compost.
  https://na.archerage.to/forums/threads/new-seeds-timers-not-halved.5310/
- The reduction is applied **per item, as custom server data**, so a new item can be missed. Example: patch 8.5 says *"Fixed a bug when Black Pepper Seed Bundle growth time didn't
  previously get custom reduction as other plants."* https://na.archerage.to/forums/threads/archerage-8-5-global-update-patch-notes.11780/
- Regrow and harvest intervals: players on the forum say re-gathering times on lemon, jujube, apple and similar trees are also halved
  (https://na.archerage.to/forums/threads/auroria-water-and-logs.5380/). A planting guide by an ArcheRage player also says "times for our server are 1/2 of those"
  (https://na.archerage.to/forums/threads/efficient-planting-and-placement-guide-contest.762/). The same thread notes that Auroria water and log *respawns* are NOT halved.
- In the seedbed thread a player gives a worked example: Cultivated Ginseng is 1d10h as a seed (17h on ArcheRage) and 24h in a seedbed (12h on ArcheRage).
  https://na.archerage.to/forums/threads/aqua-farm-bungalow-seed-beds.9434/

**JSON convention:** `baseGrowTimeMinutes` / `baseHarvestIntervalMinutes` = vanilla value from the ArcheRage DB.
`growTimeMinutes` / `harvestIntervalMinutes` = base × 0.5, the ArcheRage effective time, **in a non-native climate, unwatered**.
`witherOrDeathMinutes` is the raw tooltip value; I don't know if the server halves these.

## Mechanics
| Mechanic | Value | Status |
|---|---|---|
| Server growth rate | ×0.5 time (2x growth) for "all objects from trees to cattle" | **ArcheRage confirmed** (staff) |
| Native or matching climate | ~30% shorter (≈ ×0.70). Wiki base time = non-native time. Items with Climate Any/All get no bonus. | ArcheAge only (Reddit 2jsq0a, 253u8o; Russian guide; fandom "Ideal vs Other" columns: 2h vs 2h52m, 30m vs 43m). **Not verified on ArcheRage.** I assume it stacks multiplicatively with ×0.5. |
| Watering | Single plants −10%, seed bundles −20%. Taken off the *base* time. Only possible early (first 10% / 20% of growth). Costs labor. | ArcheAge only (helpiks.org Russian guide; blogspot guide; fandom watered values in parentheses, e.g. 30m→27m). Unverified on ArcheRage. |
| Livestock "fertilizer/feed" | Animals must be fed (Combined Feed or Ground Grain, per tooltip) to become Thriving before milk, wool or eggs can be collected. Unfed animals go Hungry and can die. Thriving but unharvested animals can become Diseased (cure with Livestock Supplement). | ArcheAge guides (blogspot 2014, fandom Livestock). The ArcheRage tooltips list the same fodder. |
| Crop withering | After maturity a crop can randomly turn Wilted or Diseased (Fertilizer or labor fixes it). In the native climate there is no explicit death timer and it can last "as much as a week". **Non-native** crops show "Nonnative Mature" with an explicit countdown, "usually a couple days". | ArcheAge Reddit only (2hsqza). **No numbers available**, so `witherOrDeathMinutes` = null. |
| Trees | Growth stages: small sapling → sapling at 10% → young at 50% → mature (fruiting trees then cycle fruit). Trees left too long go to a Dead phase. | Reddit 2jsq0a (ArcheAge). |
| Thunderstruck | Random event during non-fruit growth stages. Longer-growing trees get more chances. A thunderstruck tree lasts 2 days before decaying. Rumbling Archeum Sapling has a 10% chance. | fandom Thunderstruck_Tree (ArcheAge) |
| Seed bundles | 10 seeds → 1 bundle. Uses less space and fewer actions, gives less total yield per seed, longer timer. Some bundles are "zone agnostic". | ArcheAge sources. ArcheRage 8.5 added a **harvest-and-replant** option for 50+ bundles, woodlots and polyp bundles (flagged in `notes`). **ArcheRage confirmed.** |
| Farmhands | Plants take **20% longer** than on a normal farm. Saplings and livestock have the same maturity and recovery time. Seed bundles (added in 7.5) take **10% longer**. | **ArcheRage confirmed** (7.0 and 7.5 patch notes: threads 10966, 11219) |
| Protection / privacy | Anything planted on owned land (houses, Scarecrow gardens 8x8, Scarecrow farms 16x16, aquafarms, etc.) can't be taken without permission. Farm permissions can be set (e.g. "Open to Public" makes crops fair game). Outside protected land, tooltips say the plant "will eventually become public property". Public farms protect for 24h. Theft can be investigated and goes to trial. | tentonhammer guide (ArcheAge). The "becomes public property" text is in the ArcheRage tooltips. |
| Seedbeds (upgraded Thatched Farmhouses) | 50 seeds per bed. Timers are rounded down from the seed time and also halved on ArcheRage. | ArcheRage forum players (threads 762, 9434). No full table. |
| Rain/weather | Nothing found that says rain affects growth on either server. Climate depends on the zone; the map shows the climate at the bottom right. | gap |
| Aquafarm | Coral, kelp and oyster items only grow at Aquafarms and Marine Houses (tooltip). | ArcheRage DB |
| Beehive | Fills with honey in 1 d (2, 3 or 4 d with a Queen Bee; leaving it longer gives more honey and Royal Jelly). Not affected by climate. Consumes lumber; destroyed if unattended for long. | ArcheRage DB item 28480 |
| Pens and coops | Repair cracks (bamboo or lumber), treat disease (Livestock Supplement). "Collapsed" pens can't be used. | ArcheRage DB tooltips |

## Counts per category (farm_items.json)
| category | count | archerageConfirmed=true |
|---|---|---|
| crop (single seeds incl. zone-locked) | 53 | 52 (Wild Ginseng = false) |
| seed_bundle | 54 | 49 (5 Daru "Improved" bundles = false) |
| greenhouse | 40 | 0 |
| tree (log-only saplings) | 24 | 24 |
| fruit_tree (repeat harvest saplings, incl. Oak/Beech/Cottonwood) | 24 | 24 |
| woodlot | 8 | 5 |
| aquafarm (coral, kelp, oyster) | 21 | 16 |
| mushroom (spores) | 4 | 3 |
| livestock | 13 | 13 |
| livestock_pen (pens, coops, cages, beehive) | 12 | 8 |
| special (event, Auroria, Experia, Cornucopia, Majestic, Archeum, etc.) | 35 | 0 |
Total 288; 194 archerageConfirmed. ( `archerageConfirmed` = the base value comes from ArcheRage's own DB **and** the item falls under the documented server-wide 2x growth rule.
It is false for greenhouses, Improved/Daru items, Experia, Cornucopia, Majestic, Archeum, event items, IDs ≥ 8,000,000 (custom or late-added) and items with conflicting data, because the per-item halving can't be verified for them.)

`harvestCycles`: `1` = single harvest. An integer N = the tooltip limits it to N harvests (Hibiscus 5; Majestic, Cornucopia Tree/Crop and Mineral Archeum Tree 10; Cornucopia Cow 9 milkings; Sunglow, Dawnleaf and Topiary 3).
`null` = repeating harvest (see `harvestIntervalMinutes`) with no documented limit.

## Discrepancies (tooltip value used, object value in notes)
Small Bamboo Coop (tooltip 6h, object 12h), Daru Organic Bamboo Cage (2h40 vs 7h), Daru Rowdy Pen (8h30 vs 7h), White Coral Polyp Bundle (12h30 vs 1d4h17; probably a tooltip copy error,
since the single White Coral is 1d2h), Blue Coral Polyp Bundle 9002184 (1d14h vs 1d18h), Dawnleaf Sapling (10–20m vs 1h), Graywisp Seed (36m vs 1h12),
Unidentified Sapling (2h vs 2d20h35m) and Unidentified Seed Bundle (1h30 vs 5h43), Magic Seed, Experimental Tree, Experia Pumpkin Patch 9000366, Special Cacao Sapling (1h vs 4d6h).

## Gaps (left null; not invented)
- **Wither, death and decay timers** for normal crops, trees and livestock. No source gives numbers (only "a couple of days" for non-native crops and "up to a week" native). The only explicit lifetimes are:
  Territory Sapling (dies 1 day after it becomes harvestable), Auroria Twilight Sapling (disappears in 6 days if not tended), Unidentified Sapling and Seed Bundle (48 h), Gemblooms (24 h). Plus Thunderstruck tree (2 days, fandom; not in the JSON).
- **How many times fruit trees and livestock can be harvested** before they die or age out (fandom and the tooltips don't say). Also how many times regular livestock can be milked or sheared before the Dead phase.
- **The climate bonus % and the watering % on ArcheRage** aren't verified there. They come from 2014 official ArcheAge data. I don't know if the ×0.7 climate factor is applied before or after the ×0.5.
- **Is the halving applied to every item?** It's unknown for items added after 2018 (Auroria seeds such as Indigo Peony, Crimson Petunia and Silver Lily; Greenhouses; Improved and Daru items; Cornucopia; Mineral Archeum trees; Experia; event saplings).
  The Black Pepper Bundle bug shows that some items were missed for a while.
- Whether the explicit lifetimes (`witherOrDeathMinutes`) and the Beehive honey time are halved.
- Items in the DB with **no timer data**: Goldenbell Seed, Singing Sea-Blite Seed, Refined Grain/Spice/Fruit/Herb/Flower Seeds, Petrified Gemshrub, Coral Cactus, Tundra Fern, Violet Fiddlehead,
  Thorngrass, Goldwort Fern, Shining Vein Seed, Vita Seed, Dead Archeum Tree Sapling, Magic Bean / Dried Magic Bean, Nymphal Queen Bee (it's a beehive add-on).
- **Not included:** mount and battle-pet young (foals, yata/elk calves, leomorph/snowlion/sabrefang cubs, wolfhound pups, shoats, Mini-Miners). Their tooltips only say
  "if you don't care for the animal within 60 minutes after release, it might die", with no growth timer. Also not included: housepets, wyvern and griffin eggs, trade packs.
- Seedbed timers (thatched farmhouses) and Larders: no structured data found.
- Rain or weather effects: no evidence either way.
- Climate per housing zone is not in the dataset (the app will need a zone→climate map).

## Source reliability
| Source | Reliability for ArcheRage |
|---|---|
| wiki.archerage.to DB (items + objects) | High for base/vanilla values and item lists (it's ArcheRage's own data), **but the times shown are unhalved**. |
| na.archerage.to official forum (staff posts, patch notes) | High for server rules (2x growth, farmhand %, replant option). |
| na.archerage.to player posts | Medium (consistent anecdotes that intervals are halved). |
| archeage.fandom.com, archeagecodex.com, saarith, gameskinny | Medium. Official ArcheAge values, which match the ArcheRage DB base values. Fandom is Cloudflare-protected for curl but worked through WebFetch. |
| Reddit r/archeage (2014) and blog guides | Low–medium. Old official-server mechanics; anecdotal. |
| r/ArcheRage | Searched, but found no farming-timer threads with data. |

## Reproducing
Scripts are in `_scrape/` (they ran from /workspace with raw HTML in /workspace/raw). In order: `parse_items.py` → `extract.py` → `parse_dd.py` → `build.py` → `final.py`.

## Zone → climate map (added 2026-10-17, used by the app's zone picker)
Stored in `app/assets/zones.json` (41 zones; fields `name`, `continent`, `climates[]`, `sources[]`, optional `pvp`, `note`).
The in-game map shows the current climate at the bottom right. That is the authority; this map is a convenience.

| Continent | Temperate | Tropical | Arid | Subarctic |
|---|---|---|---|---|
| Nuia | Solzreed Peninsula, Gweonid Forest, Lilyut Hills, Dewstone Plains, White Arden, Marianople, Two Crowns, Cinderstone Moor, Halcyona, Ahnimar | Hellswamp, Sanddeep | – | Karkasse Ridgelands, Airain Rock, Aubre Cradle |
| Haranya | Falcorth Plains, Tigerspine Mountains, Villanelle, Silent Forest, Ynystere, Rookborne Basin, Hasla, Rokhala Mountains | Mahadevi, Perinoor Ruins | Arcum Iris, Solis Headlands, Windscour Savannah, Sunbite Wilds | – |
| Auroria (dual climate: the whole zone counts as both) | Calmlands, Marcala, Heedmar, Nuimari, Sungold Fields | Sungold Fields, Western Hiram Mountains | Calmlands, Marcala, Western Hiram Mountains | Heedmar, Nuimari, Western Hiram Mountains |
| Sea | Freedich Island | | | |

Sources:
- archeage.fandom.com/wiki/Climate: per-zone table for Nuia and Haranya (with PvP flag).
- archeage.fandom.com/wiki/Farms: the climate table, which adds Ahnimar, Rokhala Mountains, Sunbite Wilds, Airain Rock and Aubre Cradle.
- archeage-wiki.ru/category/ferma/klimaticheskie-zony-1580823227/: Russian wiki. It agrees with both tables above and is the only source for the Auroria pairs and for Sungold Fields (Солнечные поля: Temperate + Tropical) and Freedich Island (Остров свободы: Temperate).
- reddit.com/r/archeage/comments/2hydd2 and totalarcheage.blogspot.com (2014-11), on Auroria: Calmlands and Marcala are Temperate + Arid, Heedmar and Nuimari are Temperate + Subarctic. Reddit 2jhnjs says the whole zone counts as both climates.
- **ArcheRage-specific:** na.archerage.to/forums/threads/archerage-5-0-global-update-custom-version-patch-notes.9910/ says the **Western Hiram Mountains** (ArcheRage custom zone) "has a Tropical, Subarctic and Arid climate". It lists no Temperate.

Gaps and decisions:
- Sources disagree on which zones exist, but never on a zone's climate. Tigerspine Mountains is on the Climate page and the Russian wiki but missing from the Farms table.
- No reliable climate for **Exeloch, Diamond Shores, Mistmerrow, Eastern Hiram Mountains, Golden Ruins**. These are listed with `climates: []`, and the app doesn't auto-set the climate toggle for them. The Russian wiki has a second Temperate + Tropical zone, "Бездна", which I could not map to an English name with confidence, so I left it out.
- Item climate "Auroria" (3 items) is treated as "any Auroria zone".
- I found no ArcheRage page that confirms the climates of the standard zones. ArcheRage runs on ArcheAge data, so they are assumed unchanged.
- ArcheRage-only zones other than Western Hiram, e.g. Reedwind, aren't in the map. Their climate is unknown.
