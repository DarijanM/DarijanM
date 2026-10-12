# GreenStar terminal + nosač – model v1 (10.10.2026)

Izvor: nacrt v6 (odobren). Gradi se skriptom gs_build.py (Blender 5.2, parametarski: -- high / -- game).
Blend datoteke (master 0.6 MB, igra 0.26 MB) poslane su u chat (GreenStar_v1_paket.zip) – staviti ih u ovu mapu ručno.

## Datoteke
- greenstar_terminal_master_v1.blend – HIGH-POLY master, 29 628 tris, tipke kao zasebni objekti
- greenstar_terminal_igra_v1.blend – GAME verzija, 7 232 tris, ~26 draw callova (stari terminal ~44)
- series7810Gs_screen_v2_diffuse.png – nova podloga ekrana 512x512 (tamna, linije redova točno uz A–G, ugašeni segmenti trake) → DDS BC1 (texconv OK)
- gs_build.py – skripta za ponovnu izradu
- *_stats.txt – trokuti, materijali, clipDistance, validacija

## Koordinate i hijerarhija (Blender = lokalno u gsTerminal)
X poprijeko (0 = sredina), Y gore (0 = dno kućišta), Z prema vozaču (0 = ravnina lica, leđa Z = −64 mm).
Isti okvir kao stari gsTerminal (dno na 0, ekran X −61..44 mm kao prije), sve rotacije 0 i skale 1.

gsTerminalMount (empty – stezna ploča na B-stupu)
- gsMountParts: ploča 60x100x6, 2x M8, ušice okretnog zgloba, osovina (+ kabel u igri)
  - gsMountSwivel (pivot = vertikalna os okretanja ±30°): krak 25x16, vilica, vijak, žuti gumb
    - gsMountTilt (pivot = vodoravna os nagiba ±20°): adapter 64x80, pero lastin rep 40/52, žuti zasun
      - gsTerminal (empty, identitet)
        - gsHousing (kućište + utori; u igri i tipke + natpisi)
        - gsKey0..9, Dot, Clr, Page, Setup, Info, Run, A..G, Bright – master: mesh, igra: empty; ishodište = sredina vrha tipke
        - gsScreen → gsRowA..G / gsValA..G (Y = visina tipke), gsHdr, gsFoot (donja traka), gsScreenGlow, gsLightbar + gsLightbar_01..15
- gsMountCable (samo master; u igri spojen u gsMountParts)

PROMJENA u odnosu na v75: gsTerminal je sada dijete gsMountTilt → provjeriti i3dMappings nakon exporta.

## Materijali → i3d (vehicleShader, white_diffuse + default_vmask + detail plasticPainted)
- series7810Gs_housing_mat colorScale 0.1022 0.0578 0.0343
- series7810Gs_slot_mat 0.0232 0.0232 0.0252
- series7810Gs_key_mat 0.0762 0.0823 0.0908
- series7810Gs_print_mat 0.8879 0.8879 0.8550
- series7810Gs_yellow_mat 0.9647 0.7913 0.3095
- postojeći: steelBlack, steel (master), rubber, screen_mat (tekstura → screen_v2), lcdSeg_mat (colorScale → 0.8879 0.8879 0.8550)
clipDistance: kućište/nosač 25, tipke/ekran 15, segmenti 12. Jedan UV sloj. Nema skrivenih objekata.

## Import u series7810_ivt_igra_v75_jucer.blend
1. Backup v75. Append gsTerminalMount granu iz igra_v1.
2. Staru granu gsTerminalMount u koš (ne trajno).
3. Novi gsTerminalMount na mjesto stare ploče na B-stupu (stari root i3d t −0.701 0.243 −0.127), terminal prema vozaču; fino gsMountSwivel/gsMountTilt.
4. Premapirati .001 materijale, export (zz_v139_export + zz_post_export).
5. Lua: bijeli tekst, hmsFontThick ~1.0, hmsTextSize ~5.8, naslov stranice u donju traku.
6. Test u igri.
