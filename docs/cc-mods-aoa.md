# Моды сервера Ascension of Ages, которые работают с CC: Tweaked

Проверено 2026-11-04 по самим jar-файлам из `mods.zip` (`docs/aoa-mods.txt`):
в каждом найден код совместимости с ComputerCraft (папки `compat/computercraft`,
`compat/cc`, `integration/computer` и т.п.). Названия периферий — имена
классов из jar; точные методы проверять в игре через `tools/probe.lua`.

## Своя поддержка CC (работает без Advanced Peripherals)

| Мод | Что видит компьютер (из jar) | Чем полезно |
|---|---|---|
| **Create 6.0.10** | Station, Signal, Track Observer, TrainPass/StationTrainPresence события; Stock Ticker, Packager, Repackager, Frogport, Postbox, Redstone Requester, Table Cloth Shop; Display Link, Nixie Tube; Sequenced Gearshift, Speed Controller, Speed/Stress Gauge, Sticker, Creative Motor | диспетчер поездов, заказы со склада Create-логистики, табло, управление механизмами |
| **Create: Propulsion** | Thruster, Ion/Solid Fuel/Liquid Vector Thruster, Stirling Engine, Redstone Transmission | компьютер ведёт корабль/дирижабль |
| ↳ проверено в игре (probe, 2026-11-04) | `creative_thruster`: `setPower`, `setPowerNormalized`, `getPower`, `getTargetThrustKN/PN`, `getCurrentThrustKN/PN`, `getDisplayedThrustKN/PN`, `getThrustConfig`, `setThrustConfig`, `getAirflowMs`, `getObstruction` | |
| **Sable** (физика Aeronautics) | правка беспроводной сети CC | модемы работают на летающих/плавающих конструкциях |
| **Create: New Age** | Motor, Energiser, Carbon Brushes | электричество Create |
| **Create Crafts & Additions** | Electric/Servo Motor, Modular Accumulator, Digital Adapter, Redstone Relay, Portable Energy Interface | точные моторы и аккумуляторы |
| **Electro Energetics**, **Power Grid** | датчики тока/напряжения/мощности, батарея, сцепление генератора | энергосети Create-аддонов |
| **Mekanism** | MekanismPeripheral для машин и мультиблоков | реакторы, матрица энергии, Digital Miner — с компьютера |
| **Mekanism More Machine** | энергия машин | |
| **PneumaticCraft: Repressurized** | **Drone Interface** + периферии блоков PNC | компьютер командует дронами |
| **Immersive Engineering** | Excavator, Sample Drill, Arc Furnace, Crusher, Diesel Generator, Refinery, Mixer, Silo, Tank, Capacitor, Energy Meter, Tesla Coil, Floodlight… | промышленность IE, разведка жил буром-пробником |
| **More Immersive Wires** | провода CC на столбах IE (в т.ч. модемные) | проводная сеть компьютеров на большие расстояния |
| **Ender IO**, **HammerLib**, **ProjectRed** | bundled redstone (многожильный редстоун) | 16 сигналов по одному кабелю |
| **Supplementaries**, **Draconic Evolution** | есть код совместимости, состав уточнить в игре | |

## Работает через встроенные «общие» периферии CC
Любой блок с инвентарём, баком или энергией (сундуки, AE2-интерфейсы, баки,
аккумуляторы почти всех модов): компьютер читает содержимое и перекладывает
предметы/жидкости, видит запас энергии.

## Нужен Advanced Peripherals (в сборке его нет)
Geo Scanner (руда сквозь стены), Chunk Controller, Chat Box, Player Detector,
**ME Bridge** (AE2), **RS Bridge** (Refined Storage), Environment Detector.

## Без совместимости с CC
Integrated Dynamics (своя логика), AE2 и Refined Storage напрямую (только через
AP или как обычный инвентарь), Oritech, Occultism, Modern Industrialization.
