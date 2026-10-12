# GreenStar terminal = INFO ZASLON drugih modova i igre (10.10.2026)

## ODLUKA Darijan 10.10. 14:20 – NE PISATI KOD
Terminal je samo info zaslon (EnhancedVehicle, Courseplay, igrin pomagač). Naš HMS i većina vlastitih sustava se ukidaju zbog loše integracije s igrom. Upravljanje EV/CP s terminala se ne izvodi. Ovdje je samo popis podataka koje terminal može prikazati (provjereni API) – za kasnije.
14:21 – Darijan: dodati i info o igrinom pomagaču (helper).

## 1. EnhancedVehicle 1.1.7.1 (Majo76) – čitanje vehicle.vData
- opMode: 0 OFF / 1 DIRECTION / 2 TRACK
- is[5] snap uključen, is[6] na liniji, is[4] kut (°)
- track.workWidth (m), track.offset (m), track.deltaTrack (red)
- track.headlandMode: 1 NONE / 2 TURN / 3 CRUISE OFF; track.headlandDistance (m, 9999 = širina)
- track.origin (px, pz, dX, dZ) → bočno odstupanje od linije za lightbar
- odo/trip: is[14], is[15]

## 2. Courseplay 8.1.0.3
- getIsCpActive(), getCurrentCpCourseName(), getFieldWorkCourse():getNumberOfWaypoints()/getWorkWidth()/getLength()
- getCpFieldWorkProgress() → udio 0–1, trenutna točka, zadnja točka
- getCpActiveInfoTexts() → status (WORK_FINISHED, NEEDS_UNLOADING, FUEL_IS_LOW, IS_STUCK…)
- getCpSettings().fieldWorkSpeed / turnSpeed

## 3. Igrin pomagač (FS25 osnovna igra) – API provjeren kroz Courseplay kod koji ga koristi
- vehicle:getIsAIActive() – pomagač radi (bilo koji posao, i CP)
- vehicle:getJob() – aktivni posao; CP posao ima job.is_a(CpAIJob), igrin nema → razlikovanje "GAME HELPER" / "COURSEPLAY"
- job:getTitle(), job:getDescription() – naziv i opis posla (rad na polju, vožnja do točke, dostava…)
- job:getHelperName() / vehicle:getCurrentHelper().name – ime pomagača
- vehicle:getAIFieldWorkerIsTurning() – okreće na uvratu
- NEPROVJERENO (provjeriti u igri prije upotrebe): trošak po satu, napredak igrinog rada na polju, brzina/cilj vožnje.
- Napomena: AI vožnja isključuje našu logiku mjenjača.

## Prijedlog info stranica (nije odobren raspored)
GUIDE (EV) · COURSE (CP) · HELPER (igra): A STATUS (ACTIVE/IDLE) · B JOB (naslov) · C DESCRIPTION · D HELPER (ime) · E TURNING · F/G rezerva.
