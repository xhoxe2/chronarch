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
| ↳ установка двигателя (байткод + проверка в игре) | направление = куда смотришь при установке, `Shift` — наоборот; направление = куда толкает, струя в обратную сторону. Чтобы толкал вверх: смотреть вниз с `Shift`. Ключ у Creative Thruster меняет только вид пламени. Мощность ступенями по 1/15 (`setPowerNormalized(0.5)` → 7/15). Соседние двигатели одного направления сливаются в мультиблок | |
| ↳ мощность (байткод) | `setPower(0..15)` и `setPowerNormalized` переводят двигатель в режим компьютера (редстоун дальше не слушает). Тяга творческого = (`ThrustConfig`+1)/100 × `creativeThrusterMaxThrust` (10000 кН) × min(мощность/15, свободных блоков за соплом/10) × разгон. `setThrustConfig(0..99)`, при 0 тяга не нулевая (100 кН). Самая точная тяга — **малая мощность + большой config** (и потолок от препятствия не мешает). **Разгон**: с нуля 10 тиков (0.5 с), при выключении так же гаснет — в полёте не выключать до 0. Тяга пересчитывается на следующем тике после команды (иначе раз в 10 тиков). Препятствие пересчитывается раз в 20 тиков. У Creative Vector Thruster есть плавная `setThrustOutput(число)` | |
| **Create Simulated** (внутри `create-aeronautics-bundled`, вложенный jar — поэтому раньше не нашли) | своя поддержка CC (байткод, `compat/computercraft`): `gimbal_sensor` → `getAngles()` = массив `{X, Z}` (в игре: `[1]`, `[2]`) в градусах (`getAnglesRad`): X > 0 — ниже южный край (+z), Z > 0 — ниже восточный (+x), оси тела на момент сборки, не на теле — 0; `altitude_sensor` → `getHeight()` (мировая Y), `getAirPressure()`; `velocity_sensor` → `getVelocity()` (скорость вдоль оси датчика, со знаком); `optical_sensor` → `hasHit`, `getDistance`, `getBlock`, `getRange`, `setRange` (лазерный дальномер); `nav_table` → `getRelativeAngle` (курс на цель); ещё swivel bearing, torsion spring, docking connector (проводит проводную сеть CC), linked typewriter, name plate | автопилот: наклон, высота, скорость, расстояние до земли, курс |
| ↳ Gimbal Sensor редстоуном (Ponder) | без компьютера: сигнал в сторону наклона (восток = Z, запад = −Z, юг = X, север = −X), панель задаёт угол максимального сигнала | |
| ↳ сборка тела (проверено в игре + Ponder) | выделить суперклеем всё, что летит (вместе с компьютером и сборщиком), потом **зажать ПКМ на Physics Assembler** — у него свой рычаг, отдельный не нужен. Разбирает тело любой сборщик. Блоки по диагональным рёбрам тоже входят в тело; оторванные части отделяются в свои тела. Тело с одним двигателем по центру переворачивается, если центр тяжести не над ним | |
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
