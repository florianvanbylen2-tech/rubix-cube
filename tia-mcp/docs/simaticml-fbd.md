# SimaticML / FBD — voorbeelden voor `build_fbd_block` en `append_networks`

> **Status: ONGETEST tegen TIA Portal.** De generator is alleen lokaal gedraaid (XML-structuur klopt intern),
> maar nog niet geïmporteerd of gecompileerd in V19. Bij een importfout: roep `get_fbd_template` aan, vergelijk met
> de gegenereerde XML en pas aan in `FbdBuilder.cs`. Onzekerste punten: partnamen `A`/`O`/`X` (And/Or/Xor),
> `Coil`/`SCoil`/`RCoil` voor toewijzing/set/reset in FBD, en de namespaces `FlgNet/v4` en `Interface/v5`.

Alleen **FBD**. Operanden: `#lokaal`, `"Tag"`, `"DB"."Member"`, literals (`5`, `2.5`, `TRUE`, `T#5s`). Geen absolute adressen (`%I0.0`): gebruik tags.
Een expressie is een boom: `{operand}`, `{and:[..]}`, `{or:[..]}`, `{xor:[..]}`, `{cmp:{op,dataType,in1,in2}}`; `neg:true` negeert die ingang.

## 1. AND-box → toewijzing (FC)
```json
{"type":"FC","name":"FC_Sample","number":900,
 "interface":{"Input":[{"name":"Start","type":"Bool"},{"name":"Stop","type":"Bool"}],"Output":[{"name":"Run","type":"Bool"}]},
 "networks":[{"title":"Start en niet Stop -> Run","logic":[
   {"type":"assign","operand":"#Run","expr":{"and":[{"operand":"#Start"},{"operand":"#Stop","neg":true}]}}]}]}
```

## 2. FB-aanroep met instance-DB (bv. via `append_networks` op `Main`)
```json
[{"title":"Transportband 1","logic":[
  {"type":"call","name":"FB_Conveyor","blockType":"FB","instance":"DB_Conveyor1",
   "params":[
     {"name":"Start","section":"Input","type":"Bool","value":"\"I_Start\""},
     {"name":"Motor","section":"Output","type":"Bool","value":"\"Q_Motor\""}]}]}]
```
De instance-DB moet bestaan (`create_instance_db`) voor de FB is aangeroepen. `en` (expressie) is optioneel.

## 3. FC-aanroep met in- en uitgangen
```json
{"type":"call","name":"FC_Scale","blockType":"FC",
 "params":[
   {"name":"Raw","section":"Input","type":"Int","value":"\"DB_Data\".Raw"},
   {"name":"Scaled","section":"Output","type":"Real","value":"\"DB_Data\".Scaled"}]}
```

## 4. Vergelijker + MOVE
```json
{"logic":[
  {"type":"assign","kind":"set","operand":"\"DB_Data\".Full",
   "expr":{"cmp":{"op":">","dataType":"Int","in1":"\"DB_Data\".Count","in2":"10"}}},
  {"type":"move","en":{"operand":"\"DB_Data\".Full"},"in":"0","out":"\"DB_Data\".Count","dataType":"Int"}]}
```
`assign` met `operands:[..]` stuurt meerdere uitgangen vanuit dezelfde expressie aan.
