// WoT terrain mesh shader.
// Renders one BigWorld/WoT terrain *.cdata chunk as a regular MeshRenderer.
// This intentionally does NOT use Unity Terrain alphamaps, because Unity normalizes
// layer weights while WoT/Blender uses the raw blend weights.
Shader "WoT/TerrainChunkMesh"
{
    Properties
    {
        [HideInInspector] _Blend0 ("Blend0", 2D) = "black" {}
        [HideInInspector] _Blend1 ("Blend1", 2D) = "black" {}
        [HideInInspector] _Blend2 ("Blend2", 2D) = "black" {}
        [HideInInspector] _Blend3 ("Blend3", 2D) = "black" {}
        [HideInInspector] _Blend4 ("Blend4", 2D) = "black" {}
        [HideInInspector] _Blend5 ("Blend5", 2D) = "black" {}
        [HideInInspector] _Blend6 ("Blend6", 2D) = "black" {}
        [HideInInspector] _Blend7 ("Blend7", 2D) = "black" {}

        [HideInInspector] _Splat0 ("Splat0", 2D) = "white" {}
        [HideInInspector] _Splat1 ("Splat1", 2D) = "white" {}
        [HideInInspector] _Splat2 ("Splat2", 2D) = "white" {}
        [HideInInspector] _Splat3 ("Splat3", 2D) = "white" {}
        [HideInInspector] _Splat4 ("Splat4", 2D) = "white" {}
        [HideInInspector] _Splat5 ("Splat5", 2D) = "white" {}
        [HideInInspector] _Splat6 ("Splat6", 2D) = "white" {}
        [HideInInspector] _Splat7 ("Splat7", 2D) = "white" {}
        [HideInInspector] _Splat8 ("Splat8", 2D) = "white" {}
        [HideInInspector] _Splat9 ("Splat9", 2D) = "white" {}
        [HideInInspector] _Splat10 ("Splat10", 2D) = "white" {}
        [HideInInspector] _Splat11 ("Splat11", 2D) = "white" {}
        [HideInInspector] _Splat12 ("Splat12", 2D) = "white" {}
        [HideInInspector] _Splat13 ("Splat13", 2D) = "white" {}
        [HideInInspector] _Splat14 ("Splat14", 2D) = "white" {}
        [HideInInspector] _Splat15 ("Splat15", 2D) = "white" {}

        [HideInInspector] _GlobalMap ("Global AM", 2D) = "white" {}
        _NumLayers ("Num Layers", Float) = 0
        _NumBlends ("Num Blend Textures", Float) = 0
        _NewBlendFormat ("New Blend Format", Float) = 1
        _UseGlobalMap ("Use Global AM", Float) = 0
        _Brightness ("Preview Brightness", Float) = 1
    }

    SubShader
    {
        Tags { "RenderType"="Opaque" "RenderPipeline"="UniversalPipeline" "Queue"="Geometry" }

        Pass
        {
            Name "ForwardLit"
            Tags { "LightMode"="UniversalForward" }

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma target 3.5

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            TEXTURE2D(_Blend0); SAMPLER(sampler_Blend0);
            TEXTURE2D(_Blend1); TEXTURE2D(_Blend2); TEXTURE2D(_Blend3);
            TEXTURE2D(_Blend4); TEXTURE2D(_Blend5); TEXTURE2D(_Blend6); TEXTURE2D(_Blend7);
            TEXTURE2D(_GlobalMap);

            #define DECL_SPLAT(n) TEXTURE2D(_Splat##n);
            DECL_SPLAT(0) DECL_SPLAT(1) DECL_SPLAT(2) DECL_SPLAT(3)
            DECL_SPLAT(4) DECL_SPLAT(5) DECL_SPLAT(6) DECL_SPLAT(7)
            DECL_SPLAT(8) DECL_SPLAT(9) DECL_SPLAT(10) DECL_SPLAT(11)
            DECL_SPLAT(12) DECL_SPLAT(13) DECL_SPLAT(14) DECL_SPLAT(15)
            SAMPLER(sampler_Splat0);

            CBUFFER_START(UnityPerMaterial)
                float4 _LayerU[16];
                float4 _LayerV[16];
                float4 _LayerMode[16]; // x=1: old-format global color_tex uses whole-map/chunk UV, not tiled projection
                float4 _LayerMap[16];  // x=rotationRad, y unused, zw=Blender Mapping scale xy
                float4 _ChunkUV_ST;    // xy=1/numChunks, zw=(chunkCoord-boundsMin)/numChunks, exact Blender chunk_uv_math_node
                float4 _TerrainGlobal; // x=minWorldX, y=minWorldZ, z=sizeX, w=sizeZ
                float _NumLayers;
                float _NumBlends;
                float _NewBlendFormat;
                float _UseGlobalMap;
                float _Brightness;
            CBUFFER_END

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
                float2 uv         : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionHCS : SV_POSITION;
                float3 positionWS  : TEXCOORD0;
                float3 normalWS    : TEXCOORD1;
                float2 uv          : TEXCOORD2;
            };

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                VertexPositionInputs p = GetVertexPositionInputs(IN.positionOS.xyz);
                OUT.positionHCS = p.positionCS;
                OUT.positionWS = p.positionWS;
                OUT.normalWS = TransformObjectToWorldNormal(IN.normalOS);
                OUT.uv = IN.uv;
                return OUT;
            }

            float2 WrapWoTLayerUV(float2 uv)
            {
                // Same border avoidance as TerrainLayerMappingGroup in the Blender addon.
                const float mn = 0.0625;
                const float mx = 0.9375;
                const float span = mx - mn;
                return mn + frac((uv - mn) / span) * span;
            }

            float2 ChunkMapUV(float2 localUV)
            {
                // Exact Blender node:
                // chunk_uv_math_node = Generated * (1/numChunks) + ((hex - boundsMin)/numChunks)
                // Do this from mesh UV instead of world position so root transforms,
                // signs and floating point bounds cannot shift rows by half a tile.
                return localUV * _ChunkUV_ST.xy + _ChunkUV_ST.zw;
            }

            float2 LayerUV(int idx, float3 positionWS, float2 localUV)
            {
                // Blender special case for old terrain:
                // if not new_blend_format and 'color_tex' in layer.name, it does NOT
                // use the tiled TerrainLayerMappingGroup. It uses chunk_uv_math_node.
                if (_LayerMode[idx].x > 0.5)
                {
                    return ChunkMapUV(localUV);
                }

                // New-format WoT terrain in the Blender addon does NOT sample layers by
                // directly dotting world position with uProjection/vProjection.
                // It builds a matrix from uProjection/cross/vProjection, inverts it,
                // extracts Euler-Y and scale, then feeds those into a Mapping node.
                // The previous direct-dot mapping made atlas-like layer textures slide
                // as broad strips between chunk rows. Use the same rotation/scale
                // parameters that TerrainMeshBuilder extracts from the Blender matrix.
                float2 p = positionWS.xz;
                float a = _LayerMap[idx].x;
                float ca = cos(a);
                float sa = sin(a);
                float2 r = float2(p.x * ca - p.y * sa, p.x * sa + p.y * ca);
                // Blender Mapping node with vector_type='TEXTURE' applies mapping scale as
                // an inverse texture transform. The values we pass from C# are
                // Blender's m.to_scale() from the inverted projection matrix; for a
                // 10m tile this is about 10, but the coordinate frequency must be
                // 0.1. Therefore divide by scale, do not multiply. Multiplying here
                // was the cause of the broken unwrap / row-strip duplication.
                return WrapWoTLayerUV(r / _LayerMap[idx].zw);
            }

            float4 SampleBlend(int idx, float2 uv)
            {
                #define SAMP_B(n) if (idx == n) return SAMPLE_TEXTURE2D(_Blend##n, sampler_Blend0, uv);
                SAMP_B(0) SAMP_B(1) SAMP_B(2) SAMP_B(3) SAMP_B(4) SAMP_B(5) SAMP_B(6) SAMP_B(7)
                return float4(0,0,0,0);
                #undef SAMP_B
            }

            float3 SampleSplat(int idx, float3 positionWS, float2 localUV)
            {
                float2 uv = LayerUV(idx, positionWS, localUV);
                #define SAMP_S(n) if (idx == n) return SAMPLE_TEXTURE2D(_Splat##n, sampler_Splat0, uv).rgb;
                SAMP_S(0) SAMP_S(1) SAMP_S(2) SAMP_S(3) SAMP_S(4) SAMP_S(5) SAMP_S(6) SAMP_S(7)
                SAMP_S(8) SAMP_S(9) SAMP_S(10) SAMP_S(11) SAMP_S(12) SAMP_S(13) SAMP_S(14) SAMP_S(15)
                return float3(1,1,1);
                #undef SAMP_S
            }

            float LayerScalarWeightNewFormat(int layerIdx, float2 blendUV)
            {
                int blendIdx = layerIdx / 2;
                if (blendIdx >= (int)_NumBlends) return 0.0;
                float4 b = SampleBlend(blendIdx, blendUV);
                // Blender reference:
                // blend_texture[i].Alpha -> layer[i*2]
                // blend_texture[i].Green -> layer[i*2+1]
                return (layerIdx & 1) == 0 ? b.a : b.g;
            }

            half4 frag(Varyings IN) : SV_Target
            {
                // Blender Mapping node for blend textures uses Scale=(1,-1,1).
                float2 blendUV = float2(IN.uv.x, 1.0 - IN.uv.y);

                int n = min((int)_NumLayers, 16);
                float3 albedo = 0;
                float wsum = 0;

                if (_NewBlendFormat > 0.5)
                {
                    [loop] for (int i = 0; i < 16; i++)
                    {
                        if (i >= n) break;
                        float w = LayerScalarWeightNewFormat(i, blendUV);
                        albedo += SampleSplat(i, IN.positionWS, IN.uv) * w;
                        wsum += w;
                    }
                }
                else
                {
                    // Old format: each layer owns a PNG blend texture. Blender feeds
                    // the whole Color vector into VectorMath MULTIPLY_ADD, so keep it
                    // component-wise instead of converting to one normalized scalar.
                    [loop] for (int i = 0; i < 16; i++)
                    {
                        if (i >= n || i >= (int)_NumBlends) break;
                        float3 w = SampleBlend(i, blendUV).rgb;
                        albedo += SampleSplat(i, IN.positionWS, IN.uv) * w;
                        wsum += max(w.r, max(w.g, w.b));
                    }
                }

                if (wsum <= 1e-4)
                    albedo = SampleSplat(0, IN.positionWS, IN.uv);

                if (_UseGlobalMap > 0.5)
                {
                    // Blender also samples global AM through chunk_uv_math_node.
                    float2 guv = ChunkMapUV(IN.uv);
                    albedo *= SAMPLE_TEXTURE2D(_GlobalMap, sampler_Blend0, saturate(guv)).rgb;
                }

                float3 nWS = normalize(IN.normalWS);
                Light mainLight = GetMainLight();
                float ndotl = saturate(dot(nWS, mainLight.direction));
                float3 lit = albedo * (mainLight.color * ndotl + unity_AmbientSky.rgb + 0.20) * _Brightness;
                return half4(lit, 1);
            }
            ENDHLSL
        }

        Pass
        {
            Name "ShadowCaster"
            Tags { "LightMode"="ShadowCaster" }
            ZWrite On ZTest LEqual ColorMask 0
            HLSLPROGRAM
            #pragma vertex shadowVert
            #pragma fragment shadowFrag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            struct A { float4 positionOS : POSITION; };
            struct V { float4 positionHCS : SV_POSITION; };
            V shadowVert(A IN) { V o; o.positionHCS = TransformObjectToHClip(IN.positionOS.xyz); return o; }
            half4 shadowFrag(V IN) : SV_Target { return 0; }
            ENDHLSL
        }
    }

    Fallback "Universal Render Pipeline/Lit"
}
