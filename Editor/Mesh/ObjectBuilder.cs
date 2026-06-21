using System;
using System.Collections.Generic;
using System.IO;
using UnityEditor;
using UnityEngine;
using WoTMapImporter.Editor.Package;
using WoTMapImporter.Editor.Utils;

namespace WoTMapImporter.Editor.Mesh
{
    /// <summary>
    /// Builds static GameObjects from WoT .primitives_processed meshes and the
    /// compiled-space model hierarchy.  The object import now mirrors the Blender
    /// addon: exact render-set sections, primitive groups, uv2, flip_mat transform,
    /// all LODs, and optional destroyed variants for destructible objects.
    /// </summary>
    public static class ObjectBuilder
    {
        public class BuildResult
        {
            public GameObject Root;
            public List<GameObject> CreatedObjects = new List<GameObject>();
            public List<string> Warnings = new List<string>();
        }

        public struct ObjectTransform
        {
            public Vector4 Row0, Row1, Row2, Row3;
        }

        private sealed class BuildContext
        {
            public string OutputPath;
            public WoTPackageManager ResMgr;
            public BuildResult Result;
            public readonly Dictionary<string, UnityEngine.Mesh> MeshCache = new Dictionary<string, UnityEngine.Mesh>(StringComparer.OrdinalIgnoreCase);
            public readonly Dictionary<string, Material> MaterialCache = new Dictionary<string, Material>(StringComparer.OrdinalIgnoreCase);
            public readonly Dictionary<string, Texture2D> TextureCache = new Dictionary<string, Texture2D>(StringComparer.OrdinalIgnoreCase);
            public readonly Dictionary<string, List<AtlasEntry>> AtlasCache = new Dictionary<string, List<AtlasEntry>>(StringComparer.OrdinalIgnoreCase);
        }

        private sealed class AtlasEntry
        {
            public uint X0, X1, Y0, Y1;
            public string Path;
        }

        public static BuildResult Build(
            string outputPath,
            CompiledSpace space,
            WoTPackageManager resMgr)
        {
            var ctx = new BuildContext
            {
                OutputPath = outputPath,
                ResMgr = resMgr,
                Result = new BuildResult(),
            };

            ctx.Result.Root = new GameObject("StaticObjects");
            if (space == null || space.Placements.Count == 0)
            {
                ctx.Result.Warnings.Add("CompiledSpace has no object placements");
                return ctx.Result;
            }

            int lodVariants = 0;
            int destroyedVariants = 0;
            int renderObjects = 0;

            foreach (var placement in space.Placements)
            {
                string objectName = GetPlacementObjectName(placement);

                if (placement.DestroyedLods.Count > 0)
                {
                    // Destructible hierarchy requested by gameplay scripts:
                    // <ObjectName>/root/MainModel, DestroyedModel, CollisionTrigger/Collider.
                    var objectRoot = new GameObject(objectName);
                    objectRoot.transform.SetParent(ctx.Result.Root.transform, false);
                    ApplyWoTTransform(objectRoot.transform, placement.Transform);
                    ctx.Result.CreatedObjects.Add(objectRoot);

                    var logicalRoot = new GameObject("root");
                    logicalRoot.transform.SetParent(objectRoot.transform, false);

                    var mainModelRoot = new GameObject("MainModel");
                    mainModelRoot.transform.SetParent(logicalRoot.transform, false);
                    renderObjects += BuildLodVariant(ctx, mainModelRoot, placement.Lods, objectName + "_main");
                    if (placement.Lods.Count > 1) lodVariants++;

                    var destroyedModelRoot = new GameObject("DestroyedModel");
                    destroyedModelRoot.transform.SetParent(logicalRoot.transform, false);
                    renderObjects += BuildLodVariant(ctx, destroyedModelRoot, placement.DestroyedLods, objectName + "_destroyed");
                    destroyedModelRoot.SetActive(false); // ready for the destruction script to enable
                    destroyedVariants++;
                    if (placement.DestroyedLods.Count > 1) lodVariants++;

                    CreateCollisionTrigger(logicalRoot.transform, mainModelRoot);
                    continue;
                }

                string baseName = objectName;
                var instRoot = new GameObject(baseName);
                instRoot.transform.SetParent(ctx.Result.Root.transform, false);
                ApplyWoTTransform(instRoot.transform, placement.Transform);
                ctx.Result.CreatedObjects.Add(instRoot);

                if (placement.Lods.Count > 0)
                {
                    var intactRoot = new GameObject("Intact");
                    intactRoot.transform.SetParent(instRoot.transform, false);
                    renderObjects += BuildLodVariant(ctx, intactRoot, placement.Lods, baseName + "_intact");
                    if (placement.Lods.Count > 1) lodVariants++;
                }
            }

            ctx.Result.Warnings.Add($"Objects imported: {space.Placements.Count} placements, {renderObjects} render objects, {lodVariants} multi-LOD variants, {destroyedVariants} destroyed variants");
            return ctx.Result;
        }

        private static string GetPlacementObjectName(CompiledSpace.ModelPlacement placement)
        {
            var mesh = FirstRenderMesh(placement.Lods) ?? FirstRenderMesh(placement.DestroyedLods);
            string baseName = mesh != null && !string.IsNullOrEmpty(mesh.PrimsName)
                ? PathName(mesh.PrimsName)
                : $"model_{placement.ModelId:D5}";

            // Keep the readable game asset name but append the instance id so many
            // equal destructible props on the same map do not become impossible to
            // distinguish in the hierarchy.
            return SafeAssetName($"{baseName}_{placement.InstanceIndex:D5}");
        }

        private static CompiledSpace.RenderMesh FirstRenderMesh(List<CompiledSpace.ModelLod> lods)
        {
            if (lods == null) return null;
            foreach (var lod in lods)
                if (lod != null && lod.Meshes != null && lod.Meshes.Count > 0)
                    return lod.Meshes[0];
            return null;
        }

        private const float TriggerBoundsScale = 0.75f;
        private const float TriggerMinSize = 0.25f;

        private static void CreateCollisionTrigger(Transform logicalRoot, GameObject mainModelRoot)
        {
            var triggerRoot = new GameObject("CollisionTrigger");
            triggerRoot.transform.SetParent(logicalRoot, false);

            var colliderGo = new GameObject("Collider");
            colliderGo.transform.SetParent(triggerRoot.transform, false);

            var box = colliderGo.AddComponent<BoxCollider>();
            box.isTrigger = true;

            if (TryCalculateLocalBounds(logicalRoot, mainModelRoot, out var bounds))
            {
                Vector3 size = bounds.size * TriggerBoundsScale;
                size.x = Mathf.Max(size.x, TriggerMinSize);
                size.y = Mathf.Max(size.y, TriggerMinSize);
                size.z = Mathf.Max(size.z, TriggerMinSize);
                box.center = bounds.center;
                box.size = size;
            }
            else
            {
                // Fallback for rare broken meshes: keep a small trigger so the
                // hierarchy is still valid for the destruction script.
                box.center = Vector3.zero;
                box.size = Vector3.one;
            }
        }

        private static bool TryCalculateLocalBounds(Transform root, GameObject modelRoot, out Bounds bounds)
        {
            bounds = new Bounds(Vector3.zero, Vector3.zero);
            if (root == null || modelRoot == null) return false;

            bool has = false;
            var filters = modelRoot.GetComponentsInChildren<MeshFilter>(true);
            foreach (var mf in filters)
            {
                if (mf == null || mf.sharedMesh == null) continue;
                Matrix4x4 toRoot = root.worldToLocalMatrix * mf.transform.localToWorldMatrix;
                EncapsulateTransformedBounds(ref bounds, ref has, mf.sharedMesh.bounds, toRoot);
            }
            return has;
        }

        private static void EncapsulateTransformedBounds(ref Bounds dst, ref bool has, Bounds src, Matrix4x4 matrix)
        {
            Vector3 c = src.center;
            Vector3 e = src.extents;
            for (int ix = -1; ix <= 1; ix += 2)
            for (int iy = -1; iy <= 1; iy += 2)
            for (int iz = -1; iz <= 1; iz += 2)
            {
                Vector3 p = c + Vector3.Scale(e, new Vector3(ix, iy, iz));
                p = matrix.MultiplyPoint3x4(p);
                if (!has)
                {
                    dst = new Bounds(p, Vector3.zero);
                    has = true;
                }
                else dst.Encapsulate(p);
            }
        }

        private static int BuildLodVariant(
            BuildContext ctx,
            GameObject variantRoot,
            List<CompiledSpace.ModelLod> lods,
            string namePrefix)
        {
            int renderObjectCount = 0;
            bool visibleLodChosen = false;

            for (int li = 0; li < lods.Count; li++)
            {
                var lod = lods[li];
                string lodName = lod.Distance > 0.0001f
                    ? $"LOD{lod.LodIndex}_d{lod.Distance:0.###}"
                    : $"LOD{lod.LodIndex}";
                var lodRoot = new GameObject(lodName);
                lodRoot.transform.SetParent(variantRoot.transform, false);
                bool lodHasRenderers = false;

                foreach (var renderMesh in lod.Meshes)
                {
                    var mesh = GetOrCreateMesh(ctx, renderMesh);
                    if (mesh == null) continue;
                    var material = GetOrCreateMaterial(ctx, renderMesh, MeshHasUsefulUv2(mesh));

                    var go = new GameObject($"{namePrefix}_r{renderMesh.RenderSetId}_pg{renderMesh.PrimitiveGroup}");
                    go.transform.SetParent(lodRoot.transform, false);
                    var mf = go.AddComponent<MeshFilter>();
                    mf.sharedMesh = mesh;
                    var mr = go.AddComponent<MeshRenderer>();
                    mr.sharedMaterial = material;
                    renderObjectCount++;
                    lodHasRenderers = true;
                }

                // Keep the highest available LOD visible in the editor/imported prefab.
                // If LOD0 failed to decode for a particular asset, the next available
                // LOD becomes visible instead of leaving an empty object.
                bool active = lodHasRenderers && !visibleLodChosen;
                lodRoot.SetActive(active);
                if (active) visibleLodChosen = true;
            }

            // Do not add Unity LODGroup automatically.  WoT LOD distances do not
            // map 1:1 to Unity screen-relative heights, and auto switching made many
            // imported objects look like LOD0 was missing.  The original hierarchy is
            // still preserved: the highest successfully decoded LOD is active, the
            // remaining LOD roots are disabled child dummies.

            return renderObjectCount;
        }

        private static float ComputeLodTransition(int index, int count)
        {
            if (count <= 1) return 0.01f;
            if (index >= count - 1) return 0.01f;
            float h = 0.65f / (index + 1);
            return Mathf.Clamp(h, 0.03f, 0.8f);
        }

        private static bool MeshHasUsefulUv2(UnityEngine.Mesh mesh)
        {
            if (mesh == null) return false;
            var uv2 = mesh.uv2;
            if (uv2 == null || uv2.Length != mesh.vertexCount) return false;
            for (int i = 0; i < uv2.Length; i++)
            {
                if (Mathf.Abs(uv2[i].x) > 1e-6f || Mathf.Abs(uv2[i].y) > 1e-6f)
                    return true;
            }
            return false;
        }

        private static UnityEngine.Mesh GetOrCreateMesh(BuildContext ctx, CompiledSpace.RenderMesh renderMesh)
        {
            string key = $"{renderMesh.PrimsName}|{renderMesh.VertsDataName}|{renderMesh.PrimsDataName}|{renderMesh.PrimitiveGroup}";
            if (ctx.MeshCache.TryGetValue(key, out var cached)) return cached;

            byte[] data = ctx.ResMgr.ReadBytes(renderMesh.PrimsName) ?? TryAlternateBytes(ctx.ResMgr, renderMesh.PrimsName);
            if (data == null)
            {
                string msg = $"prims not found: {renderMesh.PrimsName}";
                ctx.Result.Warnings.Add(msg);
                WoTLogger.Warn(msg);
                return null;
            }

            MeshDataDecoder.DecodedMesh decoded;
            try
            {
                decoded = MeshDataDecoder.Decode(data, renderMesh.VertsDataName, renderMesh.PrimsDataName, renderMesh.PrimitiveGroup);
            }
            catch (Exception e)
            {
                string msg = $"Failed to decode {renderMesh.PrimsName} ({renderMesh.PrimsDataName}/{renderMesh.VertsDataName}, pg={renderMesh.PrimitiveGroup}): {e.Message}";
                ctx.Result.Warnings.Add(msg);
                WoTLogger.Warn(msg);
                return null;
            }

            var vertices = new Vector3[decoded.Positions.Length];
            for (int i = 0; i < decoded.Positions.Length; i++)
            {
                // Blender reference: bmesh.transform(flip_mat), where flip_mat maps XZY -> XYZ.
                var p = decoded.Positions[i];
                vertices[i] = new Vector3(p.x, p.z, p.y);
            }

            string meshAssetKey = $"{renderMesh.PrimsName}|{renderMesh.VertsDataName}|{renderMesh.PrimsDataName}|{renderMesh.PrimitiveGroup}";
            var umesh = new UnityEngine.Mesh
            {
                name = SafeAssetName($"{PathName(renderMesh.PrimsName)}_{renderMesh.VertsDataName}_{renderMesh.PrimsDataName}_pg{renderMesh.PrimitiveGroup}_{StableHash32(meshAssetKey):X8}"),
                indexFormat = vertices.Length > 65535
                    ? UnityEngine.Rendering.IndexFormat.UInt32
                    : UnityEngine.Rendering.IndexFormat.UInt16,
            };
            umesh.vertices = vertices;
            umesh.uv = decoded.Uv ?? Array.Empty<Vector2>();
            if (decoded.Uv2 != null) umesh.uv2 = decoded.Uv2;
            umesh.triangles = decoded.Indices ?? Array.Empty<int>();
            umesh.RecalculateNormals();
            try { umesh.RecalculateTangents(); } catch { /* older Unity / degenerate mesh */ }
            umesh.RecalculateBounds();

            string meshPath = $"{ctx.OutputPath}/Meshes/{umesh.name}.asset";
            SaveAsset(umesh, meshPath);
            var persisted = AssetDatabase.LoadAssetAtPath<UnityEngine.Mesh>(meshPath) ?? umesh;
            ctx.MeshCache[key] = persisted;
            return persisted;
        }

        private static Material GetOrCreateMaterial(BuildContext ctx, CompiledSpace.RenderMesh renderMesh, bool useUv2Blend)
        {
            string key = $"{renderMesh.MaterialIndex}|{renderMesh.FxName}|{renderMesh.Identifier}|uv2={useUv2Blend}|{PropsHash(renderMesh)}";
            if (ctx.MaterialCache.TryGetValue(key, out var cached)) return cached;

            Shader sh = Shader.Find("WoT/ObjectPBS") ??
                        Shader.Find("Universal Render Pipeline/Lit") ??
                        Shader.Find("HDRP/Lit") ??
                        Shader.Find("Standard") ??
                        Shader.Find("Sprites/Default");
            var mat = new Material(sh)
            {
                name = SafeAssetName($"WoT_Mat_{renderMesh.MaterialIndex}_{PathName(renderMesh.PrimsName)}_{renderMesh.PrimitiveGroup}_{StableHash32(key):X8}"),
            };
            SetFloatIfExists(mat, "_UseUv2Blend", useUv2Blend ? 1f : 0f);

            string fx = renderMesh.FxName ?? string.Empty;
            if (fx.IndexOf("PBS_tiled_atlas", StringComparison.OrdinalIgnoreCase) >= 0)
                SetupAtlasMaterial(ctx, mat, renderMesh);
            else if (fx.IndexOf("PBS_tiled", StringComparison.OrdinalIgnoreCase) >= 0)
                SetupTiledMaterial(ctx, mat, renderMesh);
            else
                SetupDiffuseMaterial(ctx, mat, renderMesh);

            if (mat.HasProperty("_ObjectColor"))
                mat.SetColor("_ObjectColor", renderMesh.IsDestroyedMaterial ? new Color(0.85f, 0.85f, 0.85f, 1f) : Color.white);
            if (mat.HasProperty("_FxMode")) mat.SetFloat("_FxMode", 0f);

            string matPath = $"{ctx.OutputPath}/Materials/{mat.name}.mat";
            SaveAsset(mat, matPath);
            var persisted = AssetDatabase.LoadAssetAtPath<Material>(matPath) ?? mat;
            ctx.MaterialCache[key] = persisted;
            return persisted;
        }

        private static void SetupDiffuseMaterial(BuildContext ctx, Material mat, CompiledSpace.RenderMesh renderMesh)
        {
            if (mat.HasProperty("_Mode")) mat.SetFloat("_Mode", 0f);
            Texture2D tex = LoadTextureFromProp(ctx, renderMesh, "diffuseMap", false)
                         ?? LoadTextureFromProp(ctx, renderMesh, "albedoMap", false)
                         ?? LoadTextureFromProp(ctx, renderMesh, "diffuseMap2", false);
            if (tex != null)
            {
                SetTextureIfExists(mat, "_MainTex", tex);
                SetTextureIfExists(mat, "_BaseMap", tex);
            }
            else
            {
                SetColorIfExists(mat, "_BaseColor", Color.gray);
                SetColorIfExists(mat, "_Color", Color.gray);
            }
        }

        private static void SetupTiledMaterial(BuildContext ctx, Material mat, CompiledSpace.RenderMesh renderMesh)
        {
            if (mat.HasProperty("_Mode")) mat.SetFloat("_Mode", 1f);
            Texture2D t0 = LoadTextureFromProp(ctx, renderMesh, "albedoHeightTile0", false);
            Texture2D t1 = LoadTextureFromProp(ctx, renderMesh, "albedoHeightTile1", false);
            Texture2D t2 = LoadTextureFromProp(ctx, renderMesh, "albedoHeightTile2", false);
            Texture2D blend = LoadTextureFromProp(ctx, renderMesh, "blendMask", true, true);

            if (t0 != null) { SetTextureIfExists(mat, "_Tile0", t0); SetTextureIfExists(mat, "_MainTex", t0); SetTextureIfExists(mat, "_BaseMap", t0); }
            if (t1 != null) SetTextureIfExists(mat, "_Tile1", t1);
            if (t2 != null) SetTextureIfExists(mat, "_Tile2", t2);
            if (blend != null) SetTextureIfExists(mat, "_BlendMask", blend);

            SetVectorIfExists(mat, "_Tile0Tint", ToVector4(renderMesh.GetVector("g_tile0Tint"), Color.white));
            SetVectorIfExists(mat, "_Tile1Tint", ToVector4(renderMesh.GetVector("g_tile1Tint"), Color.white));
            SetVectorIfExists(mat, "_Tile2Tint", ToVector4(renderMesh.GetVector("g_tile2Tint"), Color.white));
        }

        private static void SetupAtlasMaterial(BuildContext ctx, Material mat, CompiledSpace.RenderMesh renderMesh)
        {
            float[] atlasIndexes = renderMesh.GetVector("g_atlasIndexes") ?? new float[] { 0, 1, 2, 3 };
            float[] atlasSizes = renderMesh.GetVector("g_atlasSizes") ?? new float[] { 1, 1, 1, 1 };
            Vector4 idx = ToVector4(atlasIndexes, new Vector4(0, 1, 2, 3));
            Vector4 grid = new Vector4(
                atlasSizes.Length > 2 && Mathf.Abs(atlasSizes[2]) > 0.0001f ? atlasSizes[2] : 1f,
                atlasSizes.Length > 3 && Mathf.Abs(atlasSizes[3]) > 0.0001f ? atlasSizes[3] : 1f,
                0f, 0f);

            SetVectorIfExists(mat, "_AtlasIndexes", idx);
            SetVectorIfExists(mat, "_AtlasGrid", grid);
            SetVectorIfExists(mat, "_Tile0Tint", ToVector4(renderMesh.GetVector("g_tile0Tint"), Color.white));
            SetVectorIfExists(mat, "_Tile1Tint", ToVector4(renderMesh.GetVector("g_tile1Tint"), Color.white));
            SetVectorIfExists(mat, "_Tile2Tint", ToVector4(renderMesh.GetVector("g_tile2Tint"), Color.white));

            string atlasName = renderMesh.GetString("atlasAlbedoHeight");
            bool loadedTilesFromAtlasList = false;
            if (!string.IsNullOrEmpty(atlasName) && atlasName.EndsWith(".atlas", StringComparison.OrdinalIgnoreCase))
            {
                var entries = LoadAtlas(ctx, atlasName + "_processed");
                if (entries != null && entries.Count > 0)
                {
                    Texture2D t0 = LoadAtlasTile(ctx, entries, (int)idx.x, false);
                    Texture2D t1 = LoadAtlasTile(ctx, entries, (int)idx.y, false);
                    Texture2D t2 = LoadAtlasTile(ctx, entries, (int)idx.z, false);
                    if (t0 != null) { SetTextureIfExists(mat, "_Tile0", t0); SetTextureIfExists(mat, "_MainTex", t0); SetTextureIfExists(mat, "_BaseMap", t0); }
                    if (t1 != null) SetTextureIfExists(mat, "_Tile1", t1);
                    if (t2 != null) SetTextureIfExists(mat, "_Tile2", t2);
                    loadedTilesFromAtlasList = true;
                }
            }

            if (!loadedTilesFromAtlasList)
            {
                // Match WoT-Blender-Addons load_atlas_dds(): when atlasAlbedoHeight
                // is not a .atlas metadata file, the addon uses this same texture as
                // each tile source and only applies g_atlasIndexes[3] to atlasBlend.
                Texture2D atlasOrTile = LoadTextureByName(ctx, atlasName, false);
                if (atlasOrTile != null)
                {
                    SetTextureIfExists(mat, "_Tile0", atlasOrTile);
                    SetTextureIfExists(mat, "_Tile1", atlasOrTile);
                    SetTextureIfExists(mat, "_Tile2", atlasOrTile);
                    SetTextureIfExists(mat, "_MainTex", atlasOrTile);
                    SetTextureIfExists(mat, "_BaseMap", atlasOrTile);
                }
            }

            Texture2D blend = LoadTextureFromProp(ctx, renderMesh, "atlasBlend", true, true);
            if (blend != null)
            {
                SetTextureIfExists(mat, "_AtlasBlend", blend);
                SetTextureIfExists(mat, "_BlendMask", blend);
            }

            if (mat.HasProperty("_Mode")) mat.SetFloat("_Mode", 3f);
        }

        // =================== legacy entry point ===================

        public static BuildResult Build(
            string outputPath,
            string primsName,
            string vertsName,
            List<ObjectTransform> transforms,
            List<string> texturePaths,
            WoTPackageManager resMgr)
        {
            var result = new BuildResult();
            byte[] data = resMgr.ReadBytes(primsName) ?? TryAlternateBytes(resMgr, primsName);
            if (data == null)
            {
                result.Warnings.Add($"prims not found: {primsName}");
                return result;
            }

            MeshDataDecoder.DecodedMesh decoded;
            try { decoded = MeshDataDecoder.Decode(data, vertsName, null, -1); }
            catch (Exception e)
            {
                result.Warnings.Add($"Failed to decode {primsName}: {e.Message}");
                return result;
            }

            var vertices = new Vector3[decoded.Positions.Length];
            for (int i = 0; i < decoded.Positions.Length; i++)
                vertices[i] = new Vector3(decoded.Positions[i].x, decoded.Positions[i].z, decoded.Positions[i].y);

            var umesh = new UnityEngine.Mesh
            {
                name = SafeAssetName(PathName(primsName)),
                indexFormat = vertices.Length > 65535
                    ? UnityEngine.Rendering.IndexFormat.UInt32
                    : UnityEngine.Rendering.IndexFormat.UInt16,
            };
            umesh.vertices = vertices;
            umesh.uv = decoded.Uv;
            if (decoded.Uv2 != null) umesh.uv2 = decoded.Uv2;
            umesh.triangles = decoded.Indices;
            umesh.RecalculateNormals();
            umesh.RecalculateBounds();

            Material mat = CreatePipelineMaterial("WoT_DefaultMat");
            if (texturePaths != null && texturePaths.Count > 0 && !string.IsNullOrEmpty(texturePaths[0]))
            {
                byte[] texData = resMgr.ReadBytes(texturePaths[0]) ?? TryAlternateBytes(resMgr, texturePaths[0]);
                if (texData != null)
                {
                    var tex = LoadTex(texData, texturePaths[0], false);
                    if (tex != null) SetTextureIfExists(mat, "_MainTex", tex);
                }
            }

            result.Root = new GameObject(PathName(primsName));
            if (transforms != null)
            {
                int i = 0;
                foreach (var t in transforms)
                {
                    var inst = new GameObject(PathName(primsName) + "_inst_" + i++);
                    inst.transform.SetParent(result.Root.transform, false);
                    var mf = inst.AddComponent<MeshFilter>();
                    mf.sharedMesh = umesh;
                    var mr = inst.AddComponent<MeshRenderer>();
                    mr.sharedMaterial = mat;
                    ApplyWoTTransform(inst.transform, ToFloatArray(t));
                    result.CreatedObjects.Add(inst);
                }
            }
            else
            {
                var mf = result.Root.AddComponent<MeshFilter>();
                mf.sharedMesh = umesh;
                var mr = result.Root.AddComponent<MeshRenderer>();
                mr.sharedMaterial = mat;
                result.CreatedObjects.Add(result.Root);
            }

            string meshPath = $"{outputPath}/Meshes/{umesh.name}.asset";
            SaveAsset(umesh, meshPath);
            return result;
        }

        // =================== transform conversion ===================

        private static void ApplyWoTTransform(Transform tr, float[] rowMajor)
        {
            Matrix4x4 m = WoTMatrixToUnity(rowMajor);
            Vector3 c0 = new Vector3(m.m00, m.m10, m.m20);
            Vector3 c1 = new Vector3(m.m01, m.m11, m.m21);
            Vector3 c2 = new Vector3(m.m02, m.m12, m.m22);

            float sx = c0.magnitude;
            float sy = c1.magnitude;
            float sz = c2.magnitude;
            if (sx < 1e-7f) sx = 1f;
            if (sy < 1e-7f) sy = 1f;
            if (sz < 1e-7f) sz = 1f;

            float det = Vector3.Dot(c0, Vector3.Cross(c1, c2));
            if (det < 0f)
            {
                sx = -sx;
                c0 = -c0;
            }

            Quaternion rot = Quaternion.identity;
            try
            {
                rot = Quaternion.LookRotation(c2 / sz, c1 / sy);
            }
            catch { /* keep identity for degenerate transforms */ }

            tr.localPosition = new Vector3(m.m03, m.m13, m.m23);
            tr.localRotation = rot;
            tr.localScale = new Vector3(sx, sy, sz);
        }

        private static Matrix4x4 WoTMatrixToUnity(float[] t)
        {
            if (t == null || t.Length < 16) return Matrix4x4.identity;

            Matrix4x4 src = Matrix4x4.identity;
            src.SetRow(0, new Vector4(t[0], t[1], t[2], t[3]));
            src.SetRow(1, new Vector4(t[4], t[5], t[6], t[7]));
            src.SetRow(2, new Vector4(t[8], t[9], t[10], t[11]));
            src.SetRow(3, new Vector4(t[12], t[13], t[14], t[15]));

            Matrix4x4 flip = Matrix4x4.identity;
            flip.m11 = 0f; flip.m12 = 1f;
            flip.m21 = 1f; flip.m22 = 0f;

            // Blender: ob.matrix_world = flip_mat @ Matrix(rows).transposed() @ flip_mat
            return flip * src.transpose * flip;
        }

        private static float[] ToFloatArray(ObjectTransform t)
        {
            return new[]
            {
                t.Row0.x, t.Row0.y, t.Row0.z, t.Row0.w,
                t.Row1.x, t.Row1.y, t.Row1.z, t.Row1.w,
                t.Row2.x, t.Row2.y, t.Row2.z, t.Row2.w,
                t.Row3.x, t.Row3.y, t.Row3.z, t.Row3.w,
            };
        }

        // =================== textures/material utilities ===================

        private static Texture2D LoadTextureFromProp(BuildContext ctx, CompiledSpace.RenderMesh renderMesh, string propName, bool linear, bool pngToDds = false)
        {
            string name = renderMesh.GetString(propName);
            if (string.IsNullOrEmpty(name)) return null;
            if (pngToDds && name.EndsWith(".png", StringComparison.OrdinalIgnoreCase))
                name = name.Substring(0, name.Length - 4) + ".dds";
            return LoadTextureByName(ctx, name, linear);
        }

        private static Texture2D LoadTextureByName(BuildContext ctx, string name, bool linear)
        {
            if (string.IsNullOrEmpty(name)) return null;
            string cacheKey = (linear ? "L|" : "C|") + name.ToLowerInvariant().Replace('\\', '/');
            if (ctx.TextureCache.TryGetValue(cacheKey, out var cached)) return cached;

            byte[] data = TryResolveTexture(ctx.ResMgr, name, out string resolvedName);
            if (data == null)
            {
                WoTLogger.Warn($"Texture not found: {name}");
                return null;
            }

            Texture2D tex = LoadTex(data, resolvedName, linear);
            if (tex == null)
            {
                WoTLogger.Warn($"Texture decode failed: {resolvedName}");
                return null;
            }
            tex.name = SafeAssetName(PathName(resolvedName) + "_" + StableHash32(resolvedName).ToString("X8"));
            tex.wrapMode = TextureWrapMode.Repeat;
            tex.filterMode = FilterMode.Bilinear;

            string texPath = $"{ctx.OutputPath}/Textures/{tex.name}.asset";
            SaveAsset(tex, texPath);
            var persisted = AssetDatabase.LoadAssetAtPath<Texture2D>(texPath) ?? tex;
            ctx.TextureCache[cacheKey] = persisted;
            return persisted;
        }

        private static Texture2D LoadAtlasTile(BuildContext ctx, List<AtlasEntry> entries, int index, bool linear)
        {
            if (entries == null || index < 0 || index >= entries.Count) return null;
            return LoadTextureByName(ctx, entries[index].Path, linear);
        }

        private static List<AtlasEntry> LoadAtlas(BuildContext ctx, string name)
        {
            if (string.IsNullOrEmpty(name)) return null;
            string key = name.ToLowerInvariant().Replace('\\', '/');
            if (ctx.AtlasCache.TryGetValue(key, out var cached)) return cached;

            byte[] data = ctx.ResMgr.ReadBytes(name) ?? TryAlternateBytes(ctx.ResMgr, name);
            if (data == null) return null;

            var entries = new List<AtlasEntry>();
            try
            {
                using var ms = new MemoryStream(data, false);
                using var br = new BinaryReader(ms);
                uint version = br.ReadUInt32();
                br.ReadUInt32(); // atlas_width
                br.ReadUInt32(); // atlas_height
                br.ReadUInt32(); // unused1
                uint magic = br.ReadUInt32();
                br.ReadUInt32(); // unused2
                ulong ddsChunkSize = br.ReadUInt64();
                if (version != 1 || magic == 0)
                    return null;
                br.BaseStream.Seek((long)ddsChunkSize, SeekOrigin.Current);
                while (br.BaseStream.Position + 16 <= br.BaseStream.Length)
                {
                    var e = new AtlasEntry
                    {
                        X0 = br.ReadUInt32(),
                        X1 = br.ReadUInt32(),
                        Y0 = br.ReadUInt32(),
                        Y1 = br.ReadUInt32(),
                    };
                    var bytes = new List<byte>();
                    while (br.BaseStream.Position < br.BaseStream.Length)
                    {
                        byte b = br.ReadByte();
                        if (b == 0) break;
                        bytes.Add(b);
                    }
                    if (bytes.Count == 0) break;
                    string path = System.Text.Encoding.UTF8.GetString(bytes.ToArray()).Replace('\\', '/');
                    if (Path.HasExtension(path))
                        path = Path.ChangeExtension(path, ".dds").Replace('\\', '/');
                    e.Path = path;
                    entries.Add(e);
                }
            }
            catch (Exception e)
            {
                WoTLogger.Warn($"Atlas parse failed ({name}): {e.Message}");
                return null;
            }

            ctx.AtlasCache[key] = entries;
            return entries;
        }

        private static byte[] TryResolveTexture(WoTPackageManager resMgr, string name, out string resolved)
        {
            resolved = name;
            foreach (var c in TextureCandidates(name))
            {
                var data = resMgr.ReadBytes(c);
                if (data != null)
                {
                    resolved = c;
                    return data;
                }
            }
            return null;
        }

        private static IEnumerable<string> TextureCandidates(string name)
        {
            string n = name.Replace('\\', '/').TrimStart('/');
            yield return n;

            if (n.EndsWith(".png", StringComparison.OrdinalIgnoreCase))
                yield return n.Substring(0, n.Length - 4) + ".dds";
            if (n.EndsWith(".tga", StringComparison.OrdinalIgnoreCase))
                yield return n.Substring(0, n.Length - 4) + ".dds";
            if (!Path.HasExtension(n))
            {
                yield return n + ".dds";
                yield return n + ".png";
            }
            if (!n.StartsWith("content/", StringComparison.OrdinalIgnoreCase))
            {
                yield return "content/" + n;
                if (n.EndsWith(".png", StringComparison.OrdinalIgnoreCase))
                    yield return "content/" + n.Substring(0, n.Length - 4) + ".dds";
            }
            yield return Path.GetFileName(n);
        }

        private static byte[] TryAlternateBytes(WoTPackageManager resMgr, string name)
        {
            string n = name.Replace('\\', '/').TrimStart('/');
            var candidates = new List<string>();
            if (!n.StartsWith("content/", StringComparison.OrdinalIgnoreCase)) candidates.Add("content/" + n);
            if (!n.EndsWith("_processed", StringComparison.OrdinalIgnoreCase) && n.EndsWith(".primitives", StringComparison.OrdinalIgnoreCase))
                candidates.Add(n + "_processed");
            candidates.Add(Path.GetFileName(n));
            foreach (var c in candidates)
            {
                var data = resMgr.ReadBytes(c);
                if (data != null) return data;
            }
            return null;
        }

        private static Texture2D LoadTex(byte[] data, string name, bool linear)
        {
            try
            {
                if (data.Length >= 4 && BitConverter.ToUInt32(data, 0) == Image.DdsDecoder.MAGIC)
                {
                    // Blender flips DDS images into OpenGL/bottom-left convention.
                    // Unity's LoadRawTextureData path does not do that for DDS bytes,
                    // so object textures ended up vertically inconsistent with the
                    // UVs imported from the Blender addon.  Decode DXT1/DXT5 object
                    // DDS to RGBA32 and flip rows here; unsupported BC formats fall
                    // back to the raw compressed loader below.
                    try
                    {
                        return Image.DdsDecoder.ReadDecompressed(data, Path.GetFileNameWithoutExtension(name), linear, true);
                    }
                    catch (Exception de)
                    {
                        WoTLogger.Warn($"DDS object texture decompressed load failed ({name}): {de.Message}; falling back to raw compressed load");
                        return Image.DdsDecoder.Read(data, Path.GetFileNameWithoutExtension(name), linear);
                    }
                }
            }
            catch (Exception e)
            {
                WoTLogger.Warn($"DDS load failed ({name}): {e.Message}");
            }

            var tex = new Texture2D(2, 2, TextureFormat.RGBA32, false, linear)
            {
                name = Path.GetFileNameWithoutExtension(name),
                wrapMode = TextureWrapMode.Repeat,
                filterMode = FilterMode.Bilinear,
            };
            if (tex.LoadImage(data, false)) return tex;
            UnityEngine.Object.DestroyImmediate(tex);
            return null;
        }

        private static Material CreatePipelineMaterial(string name)
        {
            Shader sh = Shader.Find("WoT/ObjectPBS") ??
                        Shader.Find("Universal Render Pipeline/Lit") ??
                        Shader.Find("HDRP/Lit") ??
                        Shader.Find("Standard") ??
                        Shader.Find("Sprites/Default");
            return new Material(sh) { name = name };
        }

        private static void SetTextureIfExists(Material mat, string prop, Texture tex)
        {
            if (tex != null && mat.HasProperty(prop)) mat.SetTexture(prop, tex);
            if (tex != null && (prop == "_MainTex" || prop == "_BaseMap")) mat.mainTexture = tex;
        }

        private static void SetColorIfExists(Material mat, string prop, Color color)
        {
            if (mat.HasProperty(prop)) mat.SetColor(prop, color);
        }

        private static void SetVectorIfExists(Material mat, string prop, Vector4 value)
        {
            if (mat.HasProperty(prop)) mat.SetVector(prop, value);
        }

        private static void SetFloatIfExists(Material mat, string prop, float value)
        {
            if (mat.HasProperty(prop)) mat.SetFloat(prop, value);
        }

        private static Vector4 ToVector4(float[] v, Color fallback)
        {
            if (v == null || v.Length == 0) return new Vector4(fallback.r, fallback.g, fallback.b, fallback.a);
            return new Vector4(v.Length > 0 ? v[0] : fallback.r,
                               v.Length > 1 ? v[1] : fallback.g,
                               v.Length > 2 ? v[2] : fallback.b,
                               v.Length > 3 ? v[3] : fallback.a);
        }

        private static Vector4 ToVector4(float[] v, Vector4 fallback)
        {
            if (v == null || v.Length == 0) return fallback;
            return new Vector4(v.Length > 0 ? v[0] : fallback.x,
                               v.Length > 1 ? v[1] : fallback.y,
                               v.Length > 2 ? v[2] : fallback.z,
                               v.Length > 3 ? v[3] : fallback.w);
        }

        private static string PropsHash(CompiledSpace.RenderMesh mesh)
        {
            unchecked
            {
                uint h = 2166136261u;
                foreach (var kv in mesh.Props)
                {
                    h = HashStringStep(h, kv.Key);
                    if (kv.Value.StringValue != null) h = HashStringStep(h, kv.Value.StringValue);
                    h ^= kv.Value.RawValue; h *= 16777619u;
                }
                return h.ToString("X8");
            }
        }

        private static uint StableHash32(string s)
        {
            unchecked
            {
                uint h = 2166136261u;
                return HashStringStep(h, s ?? string.Empty);
            }
        }

        private static uint HashStringStep(uint h, string s)
        {
            unchecked
            {
                if (s == null) return h;
                for (int i = 0; i < s.Length; i++)
                {
                    h ^= (uint)char.ToLowerInvariant(s[i]);
                    h *= 16777619u;
                }
                return h;
            }
        }

        private static string PathName(string s)
        {
            string n = (s ?? string.Empty).Replace('\\', '/');
            int idx = n.LastIndexOf('/');
            string baseN = idx >= 0 ? n.Substring(idx + 1) : n;
            return Path.GetFileNameWithoutExtension(baseN);
        }

        private static string SafeAssetName(string s)
        {
            if (string.IsNullOrEmpty(s)) return "unnamed";
            foreach (char c in Path.GetInvalidFileNameChars())
                s = s.Replace(c, '_');
            return s.Replace('/', '_').Replace('\\', '_').Replace(':', '_');
        }

        private static void SaveAsset(UnityEngine.Object obj, string path)
        {
            path = path.Replace('\\', '/');
            EnsureFolder(Path.GetDirectoryName(path).Replace('\\', '/'));
            var existing = AssetDatabase.LoadAssetAtPath<UnityEngine.Object>(path);
            if (existing != null) AssetDatabase.DeleteAsset(path);
            AssetDatabase.CreateAsset(obj, path);
            AssetDatabase.ImportAsset(path);
        }

        private static void EnsureFolder(string folderPath)
        {
            if (string.IsNullOrEmpty(folderPath) || AssetDatabase.IsValidFolder(folderPath)) return;
            string parent = Path.GetDirectoryName(folderPath).Replace('\\', '/');
            string leaf = Path.GetFileName(folderPath);
            if (!AssetDatabase.IsValidFolder(parent)) EnsureFolder(parent);
            if (!AssetDatabase.IsValidFolder(folderPath)) AssetDatabase.CreateFolder(parent, leaf);
        }
    }
}
