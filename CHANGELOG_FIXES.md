# WoTMapImporter11 fixed build

Изменения для запроса:

1. Mesh terrain quality
   - Добавлены настройки в `Tools/WoT Map Importer`:
     - Mesh chunk resolution: 257 / 513 / 1025 / 2049
     - Baked texture resolution: 1024 / 2048 / 4096
   - Настройки сохраняются в EditorPrefs и передаются в `TerrainMeshBuilder`.

2. Terrain normal maps in mesh mode
   - В mesh-режиме для каждого чанка теперь генерируется и сохраняется baked tangent-space normal map из heightmap.
   - Normal map назначается в материал `WoT/TerrainChunkBaked` в `_NormalMap`.
   - Шейдер теперь сэмплирует normal map с тем же UV-rotation, что и baked albedo.

3. Object UV2 / atlas support
   - В комплекте оставлены исправленные `MeshDataDecoder.cs` и `ObjectBuilder.cs`, где UV2 читается из side-section `...uv2` по логике Simi4/WoT-Blender-Addons (`vertices_name[:-8] + 'uv2'`) и записывается в Unity mesh. Материалы PBS_tiled/PBS_tiled_atlas используют UV2 для blend mask при наличии полезной UV2.

Важные файлы:
- `Editor/Mesh/MeshDataDecoder.cs`
- `Editor/Mesh/ObjectBuilder.cs`
- `Editor/Terrain/TerrainMeshBuilder.cs`
- `Editor/WoTMapImporter.cs`
- `Editor/WoTMapImporterWindow.cs`
- `WoTTerrainChunkBaked.shader`
- `WoTObjectPBS.shader`

Ограничение: изменения не прогонялись в Unity/на реальных pkg в этой среде, потому что здесь нет Unity Editor и игровых ресурсов.
