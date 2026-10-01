# SimaticML / LAD — voorbeelden voor `build_lad_block` en `append_networks`

> **Status: ONGETEST tegen TIA Portal.** De generator is alleen lokaal gedraaid (XML-structuur ziet er goed uit),
> maar nog niet geïmporteerd of gecompileerd in V19. Werkwijze bij een importfout: roep `get_lad_template` aan,
> vergelijk met de gegenereerde XML en pas namespaces/elementen aan in `LadBuilder.cs`
> (constanten `Flg` = FlgNet-namespace, `Itf` = Interface-namespace).

Operanden: `#lokaal`, `"Tag"`, `"DB"."Member"`, literals (`5`, `2.5`, `TRUE`, `T#5s`). Absolute adressen (`%I0.0`) worden niet ondersteund: gebruik tags.

## 1. NO-contact → coil (FC)
```json
{"type":"FC","name":"FC_Sample","number":900,
 "interface":{"Input":[{"name":"Start","type":"Bool"}],"Output":[{"name":"Run","type":"Bool"}]},
 "networks":[{"title":"Start -> Run","logic":[
   {"type":"contact","kind":"NO","operand":"#Start"},
   {"type":"coil","operand":"#Run"}]}]}
```

## 2. FB-aanroep met instance-DB (bv. via `append_networks` op `Main`)
```json
[{"title":"Transportband 1","logic":[
  {"type":"call","name":"FB_Conveyor","blockType":"FB","instance":"DB_Conveyor1",
   "params":[
     {"name":"Start","section":"Input","type":"Bool","value":"\"I_Start\""},
     {"name":"Motor","section":"Output","type":"Bool","value":"\"Q_Motor\""}]}]}]
```
De instance-DB moet bestaan (`create_instance_db`) voor de FB is aangeroepen.

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
  {"type":"compare","op":">","dataType":"Int","in1":"\"DB_Data\".Count","in2":"10"},
  {"type":"move","in":"0","out":"\"DB_Data\".Count","dataType":"Int"}]}
```

Meerdere coils achter elkaar (`coil`, `set`, `reset`, `negcoil`) hangen parallel aan hetzelfde signaal. Parallelle contacten (OR) worden nog niet ondersteund: schrijf dan ruwe XML.
