-- =====================================================================
--  JD7810Core.lua   v8.1  (FS25 - osobna upotreba, Darijan)
--  zajednicko: postavke (jd7810Settings.xml), pomocne funkcije, konzolne naredbe, loadMap/deleteMap, registracija modula
--  v8.1: podjela JD7810Transmission.lua v8.0 na module - kod premjesten
--        bez promjene ponasanja. Redoslijed ucitavanja u modDesc.xml:
--        Core, Transmission, Engine, PTO, Display, PerformanceMonitor, Draft, AgroGsm, Cockpit
-- =====================================================================
-- =====================================================================
--  (izvorno zaglavlje JD7810Transmission.lua v8.0 - opis svih funkcija moda:)
--
--  Djeluje SAMO na ovaj traktor, ostala vozila nisu dirnuta.
--
--  MJENJAC
--   - AutoQuad nacin: automatik mijenja samo 1-4, opseg A-E biras ti
--     (kao na pravom traktoru). Moze se ukljuciti i automatski opseg.
--   - Tocke prebacivanja ovise o opterecenju (lagano rano, pod teretom
--     drzi 1650-2150 o/min).
--   - Prebacivanje nije vise "instant": kratki pad snage kod powershifta,
--     prekid snage kod opsega (spojka), minimalni razmak izmedu promjena.
--   - Na nizu brzinu spojka kratko proklizava (kocenje motorom bez trzaja).
--  MOTOR
--   - Turbo "rupa": puni moment tek kad turbo napuni (kod naglog gasa).
--   - Jacina kocenja motorom.
--  KRETANJE / STOP
--   - Trajanje proklizavanja spojke pri kretanju s mjesta.
--   - Kad stane, odmah odabere brzinu (i opseg) za kretanje prema teretu.
--  PTO
--   - 540 i 1000 PTO na nazivnih 2100 o/min (ne vise motor na maksimumu).
--  ZVUK
--   - Glasnoca mijenjanja brzina, motora i guma.
--  RUCNI GAS
--   - Numpad + / - (ili jd7810Throttle), drzi zadane okretaje motora.
--  PTO (v6)
--   - PTO ne dize okretaje sam; brzina alata = okretaji motora / nazivni.
--   - Sporiji PTO: manja radna brzina, ispod ~60% alat se zacepi.
--   - Zvuk (koraci 10%) i vrtnja dijelova alata prate PTO brzinu.
--   - PTO automatik mijenja 1-4 prema opterecenju da drzi okretaje.
--  IVT (v7)
--   - Druga konfiguracija motora u trgovini: kontinuirani prijenos, IVT konzola.
--   - Rucni gas (numpad +/-) drzi okretaje, brzinu bira tempomat/papucica (LCtrl+1 = radna brzina).
--   - IVT poluga u kabini prati brzinu voznje.
--  RADNA VOZNJA (LCtrl+1)
--   - Tempomat na radnu brzinu alata, rucni gas na nazivni PTO, opseg za tu brzinu.
--  INSTRUMENT
--   - Kompaktna ploca u stilu 90-ih: brojac okretaja + LCD + lampice, uz brzinomjer.
--
--  Postavke: jd7810Settings.xml u mapi moda. Konzola (tipka ~):
--      jd7810Help / jd7810Info / jd7810Set / jd7810Reload / jd7810Save
--      jd7810Debug
-- =====================================================================

JD7810Transmission = {}
JD7810Transmission.VERSION       = "8.2"   -- 8.2: okretaji s inercijom zamasnjaka, bez GIANTS titranja (v131); 8.1: moduli
JD7810Transmission.MOD_NAME      = g_currentModName
JD7810Transmission.MOD_DIR       = g_currentModDirectory
JD7810Transmission.SETTINGS_FILE = (g_currentModDirectory or "") .. "jd7810Settings.xml"
JD7810Transmission.XML_ROOT      = "jd7810Settings"

-- ---------------------------------------------------------------------
--  Postavke. key = ime za jd7810Set, xml = putanja u jd7810Settings.xml
-- ---------------------------------------------------------------------
JD7810Transmission.SETTINGS = {
    -- automatik
    { key = "autoShift",      type = "bool",  default = true,  xml = ".autoShift#enabled",        desc = "vlastiti automatik (off = GIANTS original)" },
    { key = "autoRange",      type = "bool",  default = false, xml = ".autoShift#autoRange",      desc = "zastarjelo od v8.0: grupe odreduje nacin voznje u igri (automatski = auto, rucno = ti)" },
    { key = "upLight",        type = "float", default = 1850,  xml = ".autoShift#upLight",        desc = "visa brzina, malo opterecenje (o/min)",               min = 1200, max = 2250 },
    { key = "psUpLight",      type = "float", default = 1950,  xml = ".autoShift#psUpLight",      desc = "Powershift: visa brzina bez tereta, i pun gas (o/min)", min = 1600, max = 2250 },
    { key = "upHeavy",        type = "float", default = 2150,  xml = ".autoShift#upHeavy",        desc = "visa brzina, puno opterecenje (o/min)",               min = 1200, max = 2250 },
    { key = "downLight",      type = "float", default = 1250,  xml = ".autoShift#downLight",      desc = "niza brzina, malo opterecenje (o/min)",               min = 900,  max = 2000 },
    { key = "downHeavy",      type = "float", default = 1650,  xml = ".autoShift#downHeavy",      desc = "niza brzina, puno opterecenje (o/min)",               min = 900,  max = 2000 },
    { key = "blockAcc",       type = "float", default = -0.05, xml = ".autoShift#blockAcc",       desc = "pod teretom nema vise ako usporava vise od (m/s2)",  min = -1.0, max = 1.0 },
    { key = "upSlipMax",      type = "float", default = 15,    xml = ".autoShift#upSlipMax",      desc = "nema vise brzine dok kotaci proklizavaju vise od ovoga (%)", min = 5, max = 60 },
    { key = "shiftInterval",  type = "float", default = 800,   xml = ".autoShift#interval",       desc = "najmanji razmak izmedu promjena, ms (niza: pola)",    min = 0,    max = 5000 },
    -- osjecaj prebacivanja
    { key = "shiftDip",       type = "float", default = 0,     xml = ".shiftFeel#dip",            desc = "pad snage pri powershiftu 0-1 (0 = instant)",         min = 0,    max = 1 },
    { key = "shiftDipTime",   type = "float", default = 0,     xml = ".shiftFeel#dipTime",        desc = "trajanje pada snage pri powershiftu, ms",             min = 0,    max = 1500 },
    { key = "rangeShiftTime", type = "float", default = 700,   xml = ".shiftFeel#rangeTime",      desc = "prekid snage pri automatskoj promjeni opsega, ms",    min = 0,    max = 2500 },
    { key = "slip",           type = "bool",  default = true,  xml = ".downshiftSlip#enabled",    desc = "proklizavanje spojke pri prebacivanju na nizu" },
    { key = "slipTime",       type = "float", default = 600,   xml = ".downshiftSlip#time",       desc = "proklizavanje bez gasa, ms (vise = mekse)",           min = 0,    max = 3000 },
    { key = "slipTimeLoad",   type = "float", default = 150,   xml = ".downshiftSlip#timeLoad",   desc = "proklizavanje pod gasom, ms",                         min = 0,    max = 3000 },
    { key = "slipTimeUp",     type = "float", default = 150,   xml = ".downshiftSlip#timeUp",     desc = "powershift na VISE: spojka preuzima postupno, ms (0 = trenutno)", min = 0,    max = 1500 },
    { key = "minSpeed",       type = "float", default = 3,     xml = ".downshiftSlip#minSpeed",   desc = "ispod ove brzine (km/h) nema proklizavanja/pada",     min = 0,    max = 40 },
    -- motor
    { key = "turbo",          type = "bool",  default = true,  xml = ".engine#turbo",             desc = "turbo rupa kod naglog gasa" },
    { key = "turboTime",      type = "float", default = 900,   xml = ".engine#turboTime",         desc = "koliko dugo turbo puni, ms",                          min = 100,  max = 4000 },
    { key = "turboMin",       type = "float", default = 0.7,   xml = ".engine#turboMin",          desc = "moment bez turba 0-1 (1 = nema rupe)",                min = 0.3,  max = 1 },
    { key = "engineBrake",    type = "float", default = 1.0,   xml = ".engine#engineBrake",       desc = "jacina kocenja motorom (1 = kao XML)",                min = 0.2,  max = 3 },
    { key = "rpmTau",         type = "float", default = 0.30,  xml = ".engine#rpmTau",            desc = "inercija zamasnjaka: vremenska konstanta okretaja, s (0 = sirovo iz fizike)", min = 0, max = 1.5 },
    { key = "fieldCruise",    type = "bool",  default = false, xml = ".fieldCruise#enabled",      desc = "Field Cruise (Darijan 6.10.: iskljuceno, kolut ostaje samo vizualno)" },
    { key = "rpmModulation",  type = "bool",  default = false, xml = ".engine#rpmModulation",     desc = "GIANTS umjetno titranje okretaja/opterecenja (zvuk, kazaljka)" },
    -- kretanje
    { key = "startSlipTime",  type = "float", default = 1500,  xml = ".start#slipTime",           desc = "proklizavanje spojke pri kretanju, ms (GIANTS 1000)", min = 300,  max = 5000 },
    -- zaustavljanje
    { key = "startGearAuto",  type = "bool",  default = true,  xml = ".stopGear#enabled",         desc = "kad stane, odmah odabere brzinu za kretanje (prema teretu i nagibu)" },
    { key = "startRange",     type = "bool",  default = true,  xml = ".stopGear#range",           desc = "pri zaustavljanju smije promijeniti i opseg A-E" },
    { key = "startRoll",      type = "float", default = 0.08,  xml = ".stopGear#roll",            desc = "otpor kotrljanja pri kretanju (polje ~0.08-0.12, cesta ~0.03)", min = 0.01, max = 0.3 },
    { key = "startAcc",       type = "float", default = 0.35,  xml = ".stopGear#acc",             desc = "zeljeno ubrzanje pri kretanju, m/s2",                 min = 0.05, max = 2 },
    { key = "startReserve",   type = "float", default = 1.3,   xml = ".stopGear#reserve",         desc = "rezerva sile stupnja za kretanje (1.3 = 30 %)",       min = 1.0,  max = 3 },
    { key = "startRpm",       type = "float", default = 1300,  xml = ".stopGear#rpm",             desc = "okretaji motora za koje se racuna moment pri kretanju", min = 900, max = 2100 },
    { key = "launchTime",     type = "float", default = 5000,  xml = ".stopGear#launchTime",      desc = "najdulje kretanje (ms) u kojem automatik ne spusta nize iz brzine za kretanje", min = 500, max = 15000 },
    { key = "startMaxKmh",    type = "float", default = 15,    xml = ".stopGear#maxKmh",          desc = "najveca brzina stupnja (pri maxRpm) u kojem se smije krenuti, km/h", min = 3, max = 45 },
    -- PTO
    { key = "ptoFix",         type = "bool",  default = true,  xml = ".pto#enabled",              desc = "PTO okretaji kao na pravom traktoru (540 i 1000 na nazivnih 2100)" },
    { key = "pto540Rpm",      type = "float", default = 2100,  xml = ".pto#rpm540",               desc = "okretaji motora za 540 PTO",                          min = 1200, max = 2300 },
    { key = "pto1000Rpm",     type = "float", default = 2100,  xml = ".pto#rpm1000",              desc = "okretaji motora za 1000 PTO",                         min = 1200, max = 2300 },
    -- rucni gas
    { key = "handStep",       type = "float", default = 100,   xml = ".handThrottle#step",        desc = "korak rucnog gasa po pritisku, o/min",                min = 10,   max = 500 },
    { key = "handMin",        type = "float", default = 900,   xml = ".handThrottle#min",         desc = "najmanje okretaje rucnog gasa (ispod = iskljucen)",   min = 850,  max = 1500 },
    { key = "handLatch",      type = "bool",  default = false, xml = ".handThrottle#latch",       desc = "stari nacin: nakon prvog gasa vozi sam na rucni gas (radna voznja = LAlt+D)" },
    { key = "handMax",        type = "float", default = 2100,  xml = ".handThrottle#max",         desc = "najvise okretaje rucnog gasa",                        min = 1200, max = 2300 },
    -- IVT regulacija okretaja (prema JD uputama OMAR195338)
    { key = "ivtMode",        type = "float", default = 2,     xml = ".ivt#mode",                 desc = "pocetni polozaj IVT biraca: 0=OFF, 1, 2, 3",           min = 0,    max = 3 },
    { key = "ivtLoadRpm",     type = "float", default = 1950,  xml = ".ivt#loadRpm",              desc = "okretaji koje IVT drzi pod opterecenjem",              min = 1200, max = 2200 },
    { key = "ivtMin1",        type = "float", default = 2000,  xml = ".ivt#min1",                 desc = "polozaj 1 (PTO/utovarivac): najmanje bez opterecenja",  min = 850,  max = 2200 },
    { key = "ivtMin2",        type = "float", default = 1500,  xml = ".ivt#min2",                 desc = "polozaj 2 (obrada): najmanje bez opterecenja",          min = 850,  max = 2200 },
    { key = "ivtMin3",        type = "float", default = 1200,  xml = ".ivt#min3",                 desc = "polozaj 3 (transport): najmanje bez opterecenja",       min = 850,  max = 2200 },
    { key = "ivtLoadOn",      type = "float", default = 0.80,  xml = ".ivt#loadOn",               desc = "opterecenje iznad kojeg IVT drzi loadRpm",              min = 0.3,  max = 1 },
    { key = "ivtLoadOff",     type = "float", default = 0.60,  xml = ".ivt#loadOff",              desc = "opterecenje ispod kojeg IVT pusta na minimum polozaja", min = 0.1,  max = 1 },
    { key = "ivtRate",        type = "float", default = 800,   xml = ".ivt#rate",                 desc = "koliko brzo se mijenja donja granica, o/min u sekundi", min = 100,  max = 5000 },
    { key = "ivtEcoReserve",  type = "float", default = 1.5,   xml = ".ivt#ecoReserve",          desc = "polozaj 2/3 stednja goriva: rezerva snage pri nizim okretajima (1.5 = 50 %)", min = 1.05, max = 2 },
    { key = "ivtOffLugRpm",   type = "float", default = 1300,  xml = ".ivt#offLugRpm",           desc = "OFF: okretaji na koje motor padne pod teretom (prozor do +200; polozaji 1-3 drze 1950)", min = 900, max = 1900 },
    -- AutoQuad II / Powershift (OMAR206904)
    { key = "aqEcoShift",     type = "float", default = 300,   xml = ".autoQuad#ecoShift",        desc = "AQ ECO: za koliko o/min ranije prebacuje na visu",    min = 0,    max = 600 },
    { key = "tyreScale",      type = "bool",  default = true,  xml = ".tyres#scale",              desc = "brzine u stupnjevima prema odabranim gumama (referenca 20.8R38)" },
    { key = "tyreRefRadius",  type = "float", default = 0.908, xml = ".tyres#refRadius",          desc = "polumjer referentne gume 20.8R38 u igri, m",          min = 0.5,  max = 1.2 },
    -- font igre na Performance Monitoru i Agro GSM (umjesto 7 segmenata)
    { key = "segFont",        type = "bool",  default = true,  xml = ".segFont#enabled",          desc = "PM i mobitel: znamenke fontom igre (off = segmenti, treba restart)" },
    { key = "segFontScale",   type = "float", default = 1.0,   xml = ".segFont#scale",            desc = "visina znaka u odnosu na razmak segmenata a-d",       min = 0.5,  max = 2 },
    { key = "segFontScaleX",  type = "float", default = 0.75,  xml = ".segFont#scaleX",           desc = "sirina znaka (sabijanje vodoravno)",                  min = 0.3,  max = 1.5 },
    { key = "segFontScaleGsm",type = "float", default = 0.85,  xml = ".segFont#scaleGsm",         desc = "dodatni faktor velicine na mobitelu",                 min = 0.3,  max = 1.5 },
    { key = "segFontYOff",    type = "float", default = 0,     xml = ".segFont#yOff",             desc = "okomiti pomak znaka (udio visine, + gore)",           min = -1,   max = 1 },
    -- vuca prikljucaka (JD7810Draft.lua, model prema ASABE D497)
    { key = "draft",          type = "bool",  default = true,  xml = ".draft#enabled",            desc = "realna vuca obradnih prikljucaka (sirina, brzina, dubina, tlo, vlaga)" },
    { key = "draftScale",     type = "float", default = 1.0,   xml = ".draft#scale",              desc = "ukupni faktor vuce (1 = model)",                     min = 0.2,  max = 3 },
    { key = "draftSoil",      type = "float", default = 2,     xml = ".draft#soil",               desc = "tlo: 1 = tesko (glina), 2 = srednje (ilovaca), 3 = lagano (pijesak)", min = 1, max = 3 },
    { key = "draftWet",       type = "float", default = 0.15,  xml = ".draft#wet",                desc = "povecanje vuce na potpuno mokrom tlu (0.15 = +15 %)", min = 0,    max = 1 },
    { key = "draftLog",       type = "bool",  default = true,  xml = ".draft#log",                desc = "test: svake 2 s u log.txt vuca, brzina, okretaji, opterecenje, IVT (dok prikljucak radi)" },
    { key = "depthPlow",      type = "float", default = 25,    xml = ".draft#depthPlow",          desc = "dubina oranja, cm",                                  min = 10,   max = 35 },
    { key = "depthDeep",      type = "float", default = 20,    xml = ".draft#depthDeep",          desc = "dubina dubokog kultivatora / chisela, cm",           min = 8,    max = 40 },
    { key = "depthCult",      type = "float", default = 10,    xml = ".draft#depthCult",          desc = "dubina kultivatora / tanjurace, cm",                 min = 3,    max = 20 },
    { key = "depthSub",       type = "float", default = 35,    xml = ".draft#depthSub",           desc = "dubina podrivaca, cm",                               min = 20,   max = 60 },
    -- otpor kotrljanja (JD7810Draft.lua): traktor + svi prikljucci/prikolice, po kotacu prema teretu kotaca i podlozi
    { key = "driveTest",      type = "float", default = 0,     xml = ".mfwd#test",                desc = "TEST pogona: 0 = iskljuceno, 1 = izmjena 6 faza po 10 s (nas MFWD / XML / 2WD / blokada / original igre / nas bez vuce)", min = 0, max = 1 },
    { key = "roll",           type = "bool",  default = true,  xml = ".rolling#enabled",          desc = "otpor kotrljanja (igra ga nema): sila = koef. podloge x teret kotaca" },
    { key = "rollScale",      type = "float", default = 1.0,   xml = ".rolling#scale",            desc = "ukupni faktor otpora kotrljanja",                     min = 0,    max = 3 },
    { key = "rollRoad",       type = "float", default = 0.015, xml = ".rolling#road",             desc = "koef. asfalt/beton/objekti",                          min = 0,    max = 0.1 },
    { key = "mfwdDynamic",    type = "bool",  default = true,  xml = ".mfwd#dynamic",             desc = "MFWD: udio momenta naprijed prema stvarnom teretu osovina (pod vucom teret prelazi straga)" },
    { key = "tractionRoad",   type = "float", default = 0.50,  xml = ".traction#road",            desc = "faktor trenja guma na asfaltu/tvrdom tlu (x frictionScale gume 1,60 -> 0,80 = stvarna guma); 1 = kao igra", min = 0.3, max = 1.5 },
    { key = "tractionField",  type = "float", default = 1.0,   xml = ".traction#field",           desc = "faktor trenja guma na polju/mekom tlu; 1 = kao igra",  min = 0.3,  max = 1.5 },
    { key = "rollHard",       type = "float", default = 0.03,  xml = ".rolling#hard",             desc = "koef. tvrdi makadam/zemljani put",                    min = 0,    max = 0.2 },
    { key = "rollSoft",       type = "float", default = 0.045, xml = ".rolling#soft",             desc = "koef. meko tlo (livada, mekani teren), suho",               min = 0,    max = 0.3 },
    { key = "rollField",      type = "float", default = 0.05,  xml = ".rolling#field",            desc = "koef. polje (strnjiste/obradeno), suho",                    min = 0,    max = 0.3 },
    { key = "rollWet",        type = "float", default = 1.0,   xml = ".rolling#wet",              desc = "povecanje na potpuno mokrom tlu (1.0 = +100 %, polje 0,05 -> 0,10)", min = 0,    max = 3 },
    { key = "ivtKnobDir",     type = "float", default = 1,     xml = ".ivt#knobDir",              desc = "smjer okretanja gumba biraca i Field Cruise (1 ili -1)", min = -1,   max = 1 },
    { key = "consoleDir",     type = "float", default = 1,     xml = ".console#dir",              desc = "smjer okretanja SCV/podizac/HMS rucica (1 ili -1)",     min = -1,   max = 1 },
    -- PTO sustav
    { key = "ptoManual",      type = "bool",  default = true,  xml = ".ptoWork#manual",           desc = "PTO ne dize okretaje sam (kao pravi 7810, okretaje das ti)" },
    { key = "ptoAutoRpm",     type = "bool",  default = true,  xml = ".ptoWork#autoRpm",          desc = "v178 ODSTUPANJE: spusten alat s PTO-om sam digne okretaje na nazivne (rucni gas ima prednost)" },
    { key = "ptoAutoRpmUp",   type = "float", default = 700,   xml = ".ptoWork#autoRpmUp",        desc = "v178: brzina dizanja okretaja (o/min u sekundi)",       min = 100, max = 3000 },
    { key = "ptoAutoRpmDown", type = "float", default = 900,   xml = ".ptoWork#autoRpmDown",      desc = "v178: brzina spustanja okretaja kad se alat digne",     min = 100, max = 3000 },
    { key = "ptoAutoLoad",    type = "bool",  default = false, xml = ".ptoWork#autoLoad",         desc = "v179: Load-based - okretaji prema snazi koju alat trazi (false = uvijek nazivni)" },
    { key = "ptoAutoMinPct",  type = "float", default = 0.85,  xml = ".ptoWork#autoMinPct",       desc = "v179: Load-based najnize (udio nazivnih okretaja; 0,85 = 1785 o/min, PTO 85 %)", min = 0.65, max = 1 },
    { key = "ptoAutoLoadLow", type = "float", default = 0.30,  xml = ".ptoWork#autoLoadLow",      desc = "v179: do ovog udjela snage motora = najnizi okretaji",  min = 0.05, max = 0.9 },
    { key = "ptoAutoLoadHigh",type = "float", default = 0.70,  xml = ".ptoWork#autoLoadHigh",     desc = "v179: od ovog udjela snage motora = nazivni okretaji",  min = 0.1,  max = 1 },
    { key = "ptoAuto",        type = "bool",  default = true,  xml = ".ptoWork#autoShift",        desc = "PTO automatik: dok radi PTO mijenja 1-4 prema opterecenju" },
    { key = "ptoSpeedLimit",  type = "bool",  default = true,  xml = ".ptoWork#speedLimit",       desc = "sporiji PTO = manja dopustena radna brzina" },
    { key = "clog",           type = "bool",  default = true,  xml = ".ptoWork#clog",             desc = "zacepljenje alata kad je PTO prespor pod opterecenjem" },
    { key = "clogPct",        type = "float", default = 0.6,   xml = ".ptoWork#clogPct",          desc = "ispod ovog udjela nazivne PTO brzine alat se zacepi",  min = 0.2,  max = 0.95 },
    { key = "clogTime",       type = "float", default = 3000,  xml = ".ptoWork#clogTime",         desc = "koliko dugo prespor PTO do zacepljenja, ms",          min = 500,  max = 20000 },
    { key = "toolSound",      type = "bool",  default = true,  xml = ".ptoWork#toolSound",        desc = "zvuk alata prati PTO brzinu (koraci 10%)" },
    { key = "toolSpin",       type = "bool",  default = true,  xml = ".ptoWork#toolSpin",         desc = "vrtnja dijelova alata prati PTO brzinu" },
    -- Performance Monitor
    { key = "pmRadar",        type = "bool",  default = true,  xml = ".perfMonitor#radar",        desc = "radarski senzor: prava brzina i proklizavanje (off = brzina s kotaca, bez proklizavanja)" },
    { key = "pmBeep",         type = "bool",  default = true,  xml = ".perfMonitor#beep",         desc = "kratki piip kod pritiska tipke monitora (IC klik i LAlt+Num)" },
    { key = "pmSlipAlarm",    type = "float", default = 15,    xml = ".perfMonitor#slipAlarm",    desc = "alarm (zvono) kad proklizavanje prijede ovaj postotak",   min = 5,    max = 40 },
    -- instrument
    -- IVT poluga (ako se u igri mice krivo)
    { key = "ivtTiltDir",     type = "float", default = 1,     xml = ".ivtLever#tiltDir",         desc = "smjer nagiba IVT poluge (1 ili -1)",                  min = -1,   max = 1 },
    { key = "ivtHandDir",     type = "float", default = 1,     xml = ".ivtLever#handDir",         desc = "smjer okretanja rucice rucnog gasa (1 ili -1)",       min = -1,   max = 1 },
    { key = "ivtSideDir",     type = "float", default = 1,     xml = ".ivtLever#sideDir",         desc = "smjer bocnog pomaka IVT poluge (1 ili -1)",           min = -1,   max = 1 },
    { key = "aqLatDir",       type = "float", default = 1,     xml = ".aqLever#latDir",           desc = "smjer bocnog pomaka AQ rucice raspona (1 ili -1)",     min = -1,   max = 1 },
    { key = "aqFaDir",        type = "float", default = 1,     xml = ".aqLever#faDir",            desc = "smjer naprijed/natrag AQ rucice raspona (1 ili -1)",   min = -1,   max = 1 },
    { key = "aqBtnDir",       type = "float", default = 1,     xml = ".aqLever#btnDir",           desc = "smjer pritiska tipki 1-4 na AQ rucici (1 ili -1)",     min = -1,   max = 1 },
    -- zvuk
    { key = "gearSound",      type = "float", default = 0.35,  xml = ".sound#gearChange",         desc = "glasnoca zvuka mijenjanja brzina/poluga (1 = original)", min = 0, max = 2 },
    { key = "gearboxSound",   type = "float", default = 1.0,   xml = ".sound#gearbox",            desc = "glasnoca zujanja mjenjaca (1 = original)",           min = 0,    max = 2 },
    { key = "engineSound",    type = "float", default = 1.25,  xml = ".sound#engine",             desc = "glasnoca motora (1 = original)",                      min = 0,    max = 2 },
    { key = "ivtRanges",      type = "bool",  default = true,  xml = ".ivtRange#enabled",         desc = "v172: IVT mehanicki stupnjevi LOW/HIGH (gubici hidraulike, AUTO traka)" },
    { key = "ivtRangeUp",     type = "float", default = 16,    xml = ".ivtRange#up",              desc = "LOW -> HIGH, km/h pri 2100 o/min (procjena)", min = 8, max = 17 },
    { key = "ivtRangeDown",   type = "float", default = 14.7,  xml = ".ivtRange#down",            desc = "HIGH -> LOW, km/h pri 2100 o/min (procjena)", min = 6, max = 16.5 },
    { key = "ivtHydroLoss",   type = "float", default = 0.10,  xml = ".ivtRange#hydroLoss",       desc = "najveci gubitak hidraulike 0-1 (0 = bez)", min = 0, max = 0.3 },
    { key = "ivtRangeDip",    type = "float", default = 0.05,  xml = ".ivtRange#dip",             desc = "pad momenta pri promjeni stupnja 0-1", min = 0, max = 0.3 },
    { key = "ivtRangeDipTime",type = "float", default = 150,   xml = ".ivtRange#dipTime",         desc = "trajanje pada momenta, ms", min = 0, max = 1000 },
    { key = "ivtRangeHud",    type = "bool",  default = true,  xml = ".ivtRange#hud",             desc = "HUD redak IVT range LOW/HIGH (informacija)" },
    { key = "powerBoost",     type = "float", default = 1.12,  xml = ".engine#powerBoost",        desc = "v173: power boost 50 km/h verzija (196/175 KS; 1 = bez)", min = 1, max = 1.3 },
    { key = "tyreModel",      type = "bool",  default = true,  xml = ".tyreModel#enabled",       desc = "v174: vuca/proklizavanje/kotrljanje prema gumi i tlu (Brixius)" },
    { key = "tyreDefl",       type = "float", default = 0.22,  xml = ".tyreModel#deflection",    desc = "ugib gume / visina boka (tlak za polje: 0,15 tvrdo napuhana - 0,30 VF)", min = 0.05, max = 0.4 },
    { key = "tyreStiffRoad",  type = "float", default = 1.0,   xml = ".tyreModel#stiffRoad",     desc = "krutost gume na cesti/tvrdom (proklizavanje pri vuci; kalibracija prema Nebraska 1807)", min = 0.5, max = 4 },
    { key = "tyreStiffField", type = "float", default = 1.0,   xml = ".tyreModel#stiffField",    desc = "krutost gume na polju (kalibracija)", min = 0.5, max = 4 },
    { key = "tyreWetGrass",   type = "float", default = 0.25,  xml = ".tyreModel#wetGrass",      desc = "mokra trava: smanjenje trenja pri punoj vlazi (0-1)", min = 0, max = 0.6 },
    { key = "tyreFurrow",     type = "bool",  default = true,  xml = ".tyreModel#furrow",        desc = "pri oranju desni kotaci na dnu brazde (tvrde tlo)" },
    { key = "tyreInflate",    type = "float", default = 0.005, xml = ".tyreModel#inflate",       desc = "v175: pumpanje bar/s (drzi RShift+Num +)", min = 0.001, max = 0.2 },
    { key = "tyreDeflate",    type = "float", default = 0.01,  xml = ".tyreModel#deflate",       desc = "v175: ispumpavanje bar/s (drzi RShift+Num -)", min = 0.001, max = 0.2 },
    { key = "tireWidthSound", type = "float", default = 1.0,   xml = ".sound#tireWidth",         desc = "v176: zvuk guma prema sirini (duple glasnije) i brzini; 0 = iskljuceno", min = 0, max = 2 },
    { key = "switchSound",    type = "float", default = 0.6,   xml = ".sound#switch",             desc = "v171: glasnoca klika prekidaca i zvuka heading locka (0 = iskljuceno)", min = 0, max = 2 },
    { key = "tireSound",      type = "float", default = 1.4,   xml = ".sound#tires",              desc = "glasnoca guma na podlozi (1 = original)",             min = 0,    max = 3 },
    -- prikaz
    { key = "debug",          type = "bool",  default = false, xml = ".debug#enabled",            desc = "poruke u konzoli/logu" },
}

JD7810Transmission.cfg = {}
for _, s in ipairs(JD7810Transmission.SETTINGS) do
    JD7810Transmission.cfg[s.key] = s.default
end

JD7810Transmission.lastEvent = ""
JD7810Transmission.lastEventTime = 0

-- ---------------------------------------------------------------------
--  Pomocne funkcije
-- ---------------------------------------------------------------------
local function log(text)
    print("JD7810: " .. text)
end

local function setEvent(text)
    JD7810Transmission.lastEvent = text
    JD7810Transmission.lastEventTime = g_time or 0
    if JD7810Transmission.cfg.debug then
        log(text)
    end
end

local function clamp(v, a, b)
    return math.max(a, math.min(b, v))
end

local function getSetting(key)
    for _, s in ipairs(JD7810Transmission.SETTINGS) do
        if string.lower(s.key) == string.lower(key) then
            return s
        end
    end
    return nil
end

local function parseBool(value)
    value = string.lower(tostring(value))
    if value == "true" or value == "1" or value == "on" or value == "da" then return true end
    if value == "false" or value == "0" or value == "off" or value == "ne" then return false end
    return nil
end

local function formatValue(s, value)
    if s.type == "bool" then
        return value and "ukljuceno" or "iskljuceno"
    end
    return string.format("%g", value)
end

local function isOurs(motor)
    if motor.jd7810IsOurs == nil then
        local ours = false
        local vehicle = motor.vehicle
        if vehicle ~= nil then
            if vehicle.customEnvironment ~= nil and vehicle.customEnvironment == JD7810Transmission.MOD_NAME then
                ours = true
            elseif vehicle.configFileName ~= nil and JD7810Transmission.MOD_DIR ~= nil then
                ours = string.find(string.lower(vehicle.configFileName), string.lower(JD7810Transmission.MOD_DIR), 1, true) ~= nil
            end
        end
        motor.jd7810IsOurs = ours
    end
    return motor.jd7810IsOurs
end

local function isAIActive(vehicle)
    if vehicle ~= nil and vehicle.getIsAIActive ~= nil then
        local ok, active = pcall(vehicle.getIsAIActive, vehicle)
        return ok and active == true
    end
    return false
end

-- PTO rucno: pravi 7810 ne dize okretaje za PTO, to radi vozac (osim kad vozi AI)
local function ptoIsManual(motor)
    return JD7810Transmission.cfg.ptoManual and isOurs(motor) and not isAIActive(motor.vehicle)
end

local function getAccelerationMS2(motor)
    return (motor.vehicle.lastSpeedAcceleration or 0) * 1000 * 1000
end

local function getSpeedKmh(motor)
    return math.abs(motor.vehicle.lastSpeed or 0) * 3600
end

-- okretaji motora s inercijom zamasnjaka (v131): filtar 1. reda nad sirovom vrijednoscu fizike (racuna JD7810Engine.lua)
local function engineRpm(motor)
    if motor.jd7810Rpm ~= nil then return motor.jd7810Rpm end
    return motor.getLastRealMotorRpm ~= nil and (motor:getLastRealMotorRpm() or 0) or 0
end

-- 0 = malo opterecenje (<=40%), 1 = puno opterecenje (>=90%)
local function getLoadFactor(motor)
    local load = motor:getSmoothLoadPercentage() or 0
    return clamp((load - 0.4) / 0.5, 0, 1)
end

-- v150: Powershift - teret iz STVARNOG otpora (bez sile za ubrzavanje), 0 = lako, 1 = puno
--   otpor = kotrljanje (izmjereno, s prikolicama) + nagib + vuca prikljucka; snaga = vrh momenta x omjer stupnja x iskoristivost
--   motor pod teretom a traktor ne ubrzava (vuca, uzbrdo) -> vrijedi i teret motora
local function psResistanceFactor(motor, load)
    local v = motor.vehicle
    local mass = 6
    if v ~= nil and v.getTotalMass ~= nil then
        local ok, m = pcall(v.getTotalMass, v, false)
        if ok and type(m) == "number" and m > 0 then mass = m end
    end
    local slope = 0
    if v ~= nil and v.rootNode ~= nil then
        local _, dy, _ = localDirectionToWorld(v.rootNode, 0, 0, 1)
        slope = (dy or 0) * ((motor.currentDirection or 1) >= 0 and 1 or -1)
    end
    local res = (motor.jd7810RollKN or mass * 9.81 * 0.02) + mass * 9.81 * math.max(slope, 0) + (motor.jd7810DraftKN or 0)
    local avail = 0
    if JD7810Transmission.stepRatio ~= nil then
        local ok, r = pcall(JD7810Transmission.stepRatio, motor, motor.currentGears, motor.gear, motor.activeGearGroupIndex, (motor.currentDirection or 1) < 0)
        local okT, tq = pcall(motor.getTorqueCurveValue, motor, 1400)
        if not okT or type(tq) ~= "number" or tq <= 0 then tq = 0.785 end
        if ok and type(r) == "number" and r > 0 then avail = tq * r * (motor.jd7810DriveEff or 0.76) end
    end
    local f = avail > 0 and clamp((res / avail - 0.25) / 0.5, 0, 1) or load
    -- v152: teska prikolica ubrzava sporo (< 0,1 m/s2) pa je pun teret motora (ubrzavanje) dizao tocku na 2150
    -- (iznad okretaja pod punim teretom) -> sada samo STALNI dio tereta: teret x otpor / (otpor + masa x a)
    local acc = getAccelerationMS2(motor)
    if acc < 0.1 then
        local steady = load * math.max(res, 0.3) / (math.max(res, 0.3) + mass * math.max(acc, 0))
        f = math.max(f, steady)
    end
    return f
end

-- tocke prebacivanja (o/min) za trenutno opterecenje
local function getShiftPoints(motor)
    local cfg = JD7810Transmission.cfg
    -- AQ AUTO (OMAR206904): automatika osjeca okretaje I polozaj gasa - pun gas = visa tocka prebacivanja
    local pedal = clamp((math.abs(motor.lastAcceleratorPedal or 0) - 0.3) / 0.6, 0, 1)
    local load = getLoadFactor(motor)
    local f = math.max(load, pedal)
    local upLight = cfg.upLight
    -- v150 Powershift (Darijan 07.10.): prazan je uvijek isao do ~2200 jer je pun gas = puno opterecenje.
    -- PS ne gleda papucicu nego stvarni otpor (kotrljanje + nagib + vuca) prema snazi u stupnju:
    -- prazan na ravnom mijenja na psUpLight (1950), s teretom / uzbrdo do upHeavy (2150).
    if JD7810Transmission.motorKind ~= nil and JD7810Transmission.motorKind(motor) == "PS" then
        upLight = cfg.psUpLight or 1950
        f = psResistanceFactor(motor, load)
    end
    -- v165 ECO (Darijan 08.10.): 0 -> 40 km/h na nizim okretajima. Na tipkovnici je W uvijek pun gas (f = 1),
    -- pa je ECO prebacivao tek na 2150 - 250. U ECO tocka vise ovisi SAMO o stvarnom teretu (prazno ~1600-1750).
    if motor.jd7810AqMode == 2 then f = load end
    local up = upLight + (cfg.upHeavy - upLight) * f
    local down = cfg.downLight + (cfg.downHeavy - cfg.downLight) * f
    if motor.jd7810AqMode == 2 then                         -- AutoQuad II ECO: ranije na visu (OMAR206904)
        up = up - (cfg.aqEcoShift or 250); down = down - (cfg.aqEcoShift or 250) * 0.5
    end
    down = math.min(down, up / 1.25)   -- razmak da nema ping-ponga (korak PowrQuada ~20%)
    return up, down, load               -- treci podatak = stvarni teret (blokada vise pod teretom), ne gas
end

local function getOurCurrentMotor()
    local vehicle
    if g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil then
        vehicle = g_localPlayer:getCurrentVehicle()
    end
    if vehicle == nil or vehicle.getMotor == nil then
        return nil
    end
    local motor = vehicle:getMotor()
    if motor ~= nil and isOurs(motor) then
        return motor
    end
    return nil
end

-- ogranicenje brzine koje igra trenutno postavlja (prikljucak, tempomat...), km/h
local function getSpeedLimitKmh(motor)
    local limit = motor.speedLimit or math.huge
    local ok, vlimit = pcall(function() return motor.vehicle:getSpeedLimit(true) end)
    if ok and type(vlimit) == "number" then
        limit = math.min(limit, vlimit)
    end
    return limit
end

local function gearText(motor)
    local ok1, group = pcall(motor.getGearGroupToDisplay, motor)
    local ok2, gear = pcall(motor.getGearToDisplay, motor)
    return string.format("%s%s", ok1 and tostring(group or "") or "", ok2 and tostring(gear or "") or "")
end

-- ---------------------------------------------------------------------
--  Postavke: citanje / spremanje XML
-- ---------------------------------------------------------------------
-- zajednicke pomocne funkcije za ostale module (JD7810*.lua)
JD7810Transmission.U = JD7810Transmission.U or {}
JD7810Transmission.U.log = log
JD7810Transmission.U.setEvent = setEvent
JD7810Transmission.U.clamp = clamp
JD7810Transmission.U.getSetting = getSetting
JD7810Transmission.U.parseBool = parseBool
JD7810Transmission.U.formatValue = formatValue
JD7810Transmission.U.isOurs = isOurs
JD7810Transmission.U.isAIActive = isAIActive
JD7810Transmission.U.ptoIsManual = ptoIsManual
JD7810Transmission.U.getAccelerationMS2 = getAccelerationMS2
JD7810Transmission.U.getSpeedKmh = getSpeedKmh
JD7810Transmission.U.engineRpm = engineRpm
JD7810Transmission.U.getLoadFactor = getLoadFactor
JD7810Transmission.U.getShiftPoints = getShiftPoints
JD7810Transmission.U.getOurCurrentMotor = getOurCurrentMotor
JD7810Transmission.U.getSpeedLimitKmh = getSpeedLimitKmh
JD7810Transmission.U.gearText = gearText

function JD7810Transmission.loadSettings()
    local file = JD7810Transmission.SETTINGS_FILE
    if file == "" or (fileExists ~= nil and not fileExists(file)) then
        log("jd7810Settings.xml nije pronaden, koristim zadane postavke (" .. file .. ")")
        return false
    end
    local xml = loadXMLFile("jd7810Settings", file)
    if xml == nil or xml == 0 then
        log("jd7810Settings.xml se ne moze otvoriti, koristim zadane postavke")
        return false
    end
    local root = JD7810Transmission.XML_ROOT
    for _, s in ipairs(JD7810Transmission.SETTINGS) do
        local path = root .. s.xml
        if hasXMLProperty(xml, path) then
            local value
            if s.type == "bool" then
                value = getXMLBool(xml, path)
            else
                value = getXMLFloat(xml, path)
                if value ~= nil and s.min ~= nil then
                    value = clamp(value, s.min, s.max)
                end
            end
            if value ~= nil then
                JD7810Transmission.cfg[s.key] = value
            end
        end
    end
    delete(xml)
    return true
end

function JD7810Transmission.saveSettings()
    local file = JD7810Transmission.SETTINGS_FILE
    local root = JD7810Transmission.XML_ROOT
    local xml = createXMLFile("jd7810Settings", file, root)
    if xml == nil or xml == 0 then
        return false
    end
    for _, s in ipairs(JD7810Transmission.SETTINGS) do
        local value = JD7810Transmission.cfg[s.key]
        if s.type == "bool" then
            setXMLBool(xml, root .. s.xml, value)
        else
            setXMLFloat(xml, root .. s.xml, value)
        end
    end
    saveXMLFile(xml)
    delete(xml)
    return true
end

function JD7810Transmission.settingsText()
    local lines = {}
    for _, s in ipairs(JD7810Transmission.SETTINGS) do
        table.insert(lines, string.format("  %-14s = %-11s %s", s.key, formatValue(s, JD7810Transmission.cfg[s.key]), s.desc))
    end
    return table.concat(lines, "\n")
end

function JD7810Transmission:consoleHelp()
    return table.concat({
        "JD7810 v" .. JD7810Transmission.VERSION .. " naredbe:",
        "  jd7810Info                 - postavke i stanje traktora",
        "  jd7810Set <kljuc> <vrij.>  - promijeni odmah, npr: jd7810Set autoRange on  /  jd7810Set shiftDip 0.3",
        "  jd7810Reload               - ponovo ucitaj jd7810Settings.xml",
        "  jd7810Save                 - spremi trenutne postavke u jd7810Settings.xml",
        "  jd7810Throttle <o/min|off> - rucni gas (ili numpad + / -)",
        "  jd7810Debug                - poruke u konzoli (ukljuci/iskljuci)",
        "  Performance Monitor: LAlt+Q / W = prethodni / sljedeci prikaz (SPD SLIP PTO AREA WORK WDTH SERV), LAlt+R = sirina +10/+20 % (u WDTH), LAlt+E = ZERO (T u AREA/WORK); ili klik (IC) na tipke monitora",
        "  Prikljucci: G = prednji/straznji/OBA (V spusta oba); SCV I-III, podizac i HMS se micu sami",
        "  IVT: LCtrl+Num 9 = birac OFF/1/2/3, Num * = Field Cruise (najvise okretaje), LAlt+C = traka 1/2/AUTO, LAlt+V/B = zadana brzina; smjer gumba: jd7810Set ivtKnobDir -1",
        "Kljucevi za jd7810Set:",
        JD7810Transmission.settingsText(),
    }, "\n")
end

function JD7810Transmission:consoleInfo()
    local text = "JD7810 v" .. JD7810Transmission.VERSION .. " postavke:\n" .. JD7810Transmission.settingsText()
    local motor = getOurCurrentMotor()
    if motor ~= nil then
        local up, down = getShiftPoints(motor)
        text = text .. string.format("\nStanje: %s | %.0f o/min (sirovo %.0f) | %.1f km/h | opterecenje %.0f%% | ubrzanje %+.2f m/s2 | turbo %.0f%%",
            gearText(motor), engineRpm(motor), motor:getLastRealMotorRpm() or 0, getSpeedKmh(motor),
            (motor:getSmoothLoadPercentage() or 0) * 100, getAccelerationMS2(motor), (motor.jd7810Boost or 0) * 100)
        text = text .. string.format("\nOgranicenje brzine (prikljucak/tempomat): %s", getSpeedLimitKmh(motor) < 39 and string.format("%.1f km/h", getSpeedLimitKmh(motor)) or "nema")
        text = text .. string.format("\nTocke prebacivanja sada: nize ispod %.0f, vise iznad %.0f o/min | opseg: %s",
            down, up, motor.gearShiftMode == VehicleMotor.SHIFT_MODE_AUTOMATIC and "automatski (nacin AUTOMATSKI)" or "rucno, 1-4 automatski (AutoQuad)")
        if JD7810Transmission.lastEvent ~= "" then
            text = text .. "\nZadnji dogadaj: " .. JD7810Transmission.lastEvent
        end
    else
        text = text .. "\n(Sjedni u JD 7810 za prikaz stanja traktora.)"
    end
    return text
end

function JD7810Transmission:consoleSet(key, value)
    if key == nil or value == nil then
        return "Upotreba: jd7810Set <kljuc> <vrijednost>\n" .. JD7810Transmission.settingsText()
    end
    local s = getSetting(key)
    if s == nil then
        return "Nepoznat kljuc '" .. tostring(key) .. "'. Moguci kljucevi:\n" .. JD7810Transmission.settingsText()
    end
    local newValue
    if s.type == "bool" then
        newValue = parseBool(value)
        if newValue == nil then
            return "Za '" .. s.key .. "' upisi on/off (ili true/false, 1/0)"
        end
    else
        newValue = tonumber(value)
        if newValue == nil then
            return "Za '" .. s.key .. "' upisi broj, npr: jd7810Set " .. s.key .. " " .. formatValue(s, s.default)
        end
        if s.min ~= nil and (newValue < s.min or newValue > s.max) then
            return string.format("'%s' mora biti izmedu %g i %g", s.key, s.min, s.max)
        end
    end
    JD7810Transmission.cfg[s.key] = newValue
    return string.format("%s = %s  (vrijedi odmah; za trajno spremanje upisi jd7810Save)", s.key, formatValue(s, newValue))
end

function JD7810Transmission:consoleReload()
    for _, s in ipairs(JD7810Transmission.SETTINGS) do
        JD7810Transmission.cfg[s.key] = s.default
    end
    local ok = JD7810Transmission.loadSettings()
    return (ok and "jd7810Settings.xml ponovo ucitan:\n" or "Datoteka nije ucitana, vracene zadane postavke:\n") .. JD7810Transmission.settingsText()
end

function JD7810Transmission:consoleSave()
    if JD7810Transmission.saveSettings() then
        return "Postavke spremljene u " .. JD7810Transmission.SETTINGS_FILE
    end
    return "Spremanje nije uspjelo (" .. JD7810Transmission.SETTINGS_FILE .. ")"
end

function JD7810Transmission:consoleThrottle(value)
    local motor = getOurCurrentMotor()
    if motor == nil then
        return "Sjedni u JD 7810."
    end
    if value == nil or string.lower(value) == "off" or tonumber(value) == 0 then
        JD7810Transmission.setHandThrottle(motor, nil)
        return "Hand throttle off"
    end
    local rpm = tonumber(value)
    if rpm == nil then
        return "Upotreba: jd7810Throttle <o/min>  ili  jd7810Throttle off"
    end
    JD7810Transmission.setHandThrottle(motor, rpm)
    return (motor.jd7810HandRpm or 0) > 0 and string.format("Hand throttle: %.0f rpm", motor.jd7810HandRpm) or "Hand throttle off (below minimum)"
end

function JD7810Transmission:consoleWork()
    local motor = getOurCurrentMotor()
    if motor == nil then
        return "Sjedni u JD 7810."
    end
    JD7810Transmission.toggleWorkDrive(motor.vehicle)
    return JD7810Transmission.lastEvent
end

function JD7810Transmission:consoleDebug()
    JD7810Transmission.cfg.debug = not JD7810Transmission.cfg.debug
    return "Debug poruke: " .. (JD7810Transmission.cfg.debug and "ukljucene" or "iskljucene")
end

JD7810Transmission.COMMANDS = {
    { "jd7810Help",   "JD7810: popis naredbi",                              "consoleHelp",   "" },
    { "jd7810Info",   "JD7810: postavke i stanje traktora",                 "consoleInfo",   "" },
    { "jd7810Set",    "JD7810: promijeni postavku odmah",                   "consoleSet",    "kljuc; vrijednost" },
    { "jd7810Reload", "JD7810: ponovo ucitaj jd7810Settings.xml",           "consoleReload", "" },
    { "jd7810Save",   "JD7810: spremi postavke u jd7810Settings.xml",       "consoleSave",   "" },
    { "jd7810Throttle", "JD7810: rucni gas (o/min ili off)",                "consoleThrottle", "o/min | off" },
    { "jd7810Work",   "JD7810: radna voznja ukljuci/iskljuci (ili LAlt+D)", "consoleWork", "" },
    { "jd7810Debug",  "JD7810: poruke u konzoli (ukljuci/iskljuci)",        "consoleDebug",  "" },
}

-- =====================================================================
--  Mod event listener: naredbe + prikaz na ekranu
-- =====================================================================
function JD7810Transmission:loadMap(name)
    pcall(JD7810Transmission.registerIC)
    for _, c in ipairs(JD7810Transmission.COMMANDS) do
        addConsoleCommand(c[1], c[2], c[3], JD7810Transmission, c[4])
    end
    if JD7810Transmission.hudCreate ~= nil then pcall(JD7810Transmission.hudCreate) end
    log("naredbe spremne - upisi jd7810Help u konzolu")
end

function JD7810Transmission:deleteMap()
    for tool, _ in pairs(JD7810Transmission.tools) do
        pcall(JD7810Transmission.U.restoreTool, tool)
    end
    for tool, _ in pairs(JD7810Transmission.draftTools or {}) do              -- vuca: vrati maxForce prikljucaka
        if JD7810Transmission.U.restoreDraft ~= nil then pcall(JD7810Transmission.U.restoreDraft, tool) end
    end
    JD7810Transmission.draftTools = {}
    for tool, _ in pairs(JD7810Transmission.pmScaled or {}) do
        local st = JD7810Transmission.pmScaled[tool]                       -- prikljucak mozda vec obrisan (izlaz iz igre)
        for _, e in ipairs(st ~= nil and st.nodes or {}) do
            if entityExists ~= nil and entityExists(e[1]) then setTranslation(e[1], e[2], e[3], e[4]) end
        end
    end
    JD7810Transmission.pmScaled = {}
    JD7810Transmission.pmStates = {}                                         -- stanje po traktoru: novo ucitavanje iz savegamea
    if JD7810Transmission.hudDelete ~= nil then pcall(JD7810Transmission.hudDelete) end
    for _, c in ipairs(JD7810Transmission.COMMANDS) do
        removeConsoleCommand(c[1])
    end
end

addModEventListener(JD7810Transmission)
