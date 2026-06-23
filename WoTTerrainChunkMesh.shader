// WoT terrain mesh shader.
// Renders one BigWorld/WoT terrain *.cdata chunk as a regular MeshRenderer.
// This intentionally does NOT use Unity Terrain alphamaps, because Unity normalizes
// layer weights while WoT/Blender uses the raw blend weights.
//
// Normal map support:
//   _NormalMap / _BumpMap assigned in C# → tangent-space bump shading enabled.
Shader "WoT/TerrainChunkMesh"
{
    Properties
    {
        [HideInInspector] _Blend0  ("Blend0",  2D) = "black" {}
        [HideInInspector] _Blend1  ("Blend1",  2D) = "black" {}
        [HideInInspector] _Blend2  ("Blend2",  2D) = "black" {}
        [HideInInspector] _Blend3  ("Blend3",  2D) = "black" {}
        [HideInInspector] _Blend4  ("Blend4",  2D) = "black" {}
        [HideInInspector] _Blend5  ("Blend5",  2D) = "black" {}
        [HideInInspector] _Blend6  ("Blend6",  2D) = "black" {}
        [HideInInspector] _Blend7  ("Blend7",  2D) = "black" {}

        [HideInInspector] _Splat0  ("Splat0",  2D) = "white" {}
        [HideInInspector] _Splat1  ("Splat1",  2D) = "white" {}
        [HideInInspector] _Splat2  ("Splat2",  2D) = "white" {}
        [HideInInspector] _Splat3  ("Splat3",  2D) = "white" {}
        [HideInInspector] _Splat4  ("Splat4",  2D) = "white" {}
        [HideInInspector] _Splat5  ("Splat5",  2D) = "white" {}
        [HideInInspector] _Splat6  ("Splat6",  2D) = "white" {}
        [HideInInspector] _Splat7  ("Splat7",  2D) = "white" {}
        [HideInInspector] _Splat8  ("Splat8",  2D) = "white" {}
        [HideInInspector] _Splat9  ("Splat9",  2D) = "white" {}
        [HideInInspector] _Splat10 ("Splat10", 2D) = "white" {}
        [HideInInspector] _Splat11 ("Splat11", 2D) = "white" {}
        [HideInInspector] _Splat12 ("Splat12", 2D) = "white" {}
        [HideInInspector] _Splat13 ("Splat13", 2D) = "white" {}
        [HideInInspector] _Splat14 ("Splat14", 2D) = "white" {}
        [HideInInspector] _Splat15 ("Splat15", 2D) = "white" {}

        // Per-layer normal maps (same naming pattern as albedo splats).
        [HideInInspector] [Normal] _Normal0  ("Normal0",  2D) = "bump" {}
        [HideInInspector] [Normal] _Normal1  ("Normal1",  2D) = "bump" {}
        [HideInInspector] [Normal] _Normal2  ("Normal2",  2D) = "bump" {}
        [HideInInspector] [Normal] _Normal3  ("Normal3",  2D) = "bump" {}
        [HideInInspector] [Normal] _Normal4  ("Normal4",  2D) = "bump" {}
        [HideInInspector] [Normal] _Normal5  ("Normal5",  2D) = "bump" {}
        [HideInInspector] [Normal] _Normal6  ("Normal6",  2D) = "bump" {}
        [HideInInspector] [Normal] _Normal7  ("Normal7",  2D) = "bump" {}
        [HideInInspector] [Normal] _Normal8  ("Normal8",  2D) = "bump" {}
        [HideInInspector] [Normal] _Normal9  ("Normal9",  2D) = "bump" {}
        [HideInInspector] [Normal] _Normal10 ("Normal10", 2D) = "bump" {}
        [HideInInspector] [Normal] _Normal11 ("Normal11", 2D) = "bump" {}
        [HideInInspector] [Normal] _Normal12 ("Normal12", 2D) = "bump" {}
        [HideInInspector] [Normal] _Normal13 ("Normal13", 2D) = "bump" {}
        [HideInInspector] [Normal] _Normal14 ("Normal14", 2D) = "bump" {}
        [HideInInspector] [Normal] _Normal15 ("Normal15", 2D) = "bump" {}

        [HideInInspector] _GlobalMap ("Global AM", 2D) = "white" {}
        _NumLayers       ("Num Layers",          Float) = 0
        _NumBlends       ("Num Blend Textures",   Float) = 0
        _NewBlendFormat  ("New Blend Format",     Float) = 1
        _UseGlobalMap    ("Use Global AM",        Float) = 0
        _Brightness      ("Preview Brightness",   Float) = 1
        _BumpScale       ("Normal Scale",         Float) = 1.0
        _UseNormalMaps   ("Use Normal Maps",      Float) = 1
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
            DECL_SPLAT(0)  DECL_SPLAT(1)  DECL_SPLAT(2)  DECL_SPLAT(3)
            DECL_SPLAT(4)  DECL_SPLAT(5)  DECL_SPLAT(6)  DECL_SPLAT(7)
            DECL_SPLAT(8)  DECL_SPLAT(9)  DECL_SPLAT(10) DECL_SPLAT(11)
            DECL_SPLAT(12) DECL_SPLAT(13) DECL_SPLAT(14) DECL_SPLAT(15)
            SAMPLER(sampler_Splat0);

            #define DECL_NORM(n) TEXTURE2D(_Normal##n);
            DECL_NORM(0)  DECL_NORM(1)  DECL_NORM(2)  DECL_NORM(3)
            DECL_NORM(4)  DECL_NORM(5)  DECL_NORM(6)  DECL_NORM(7)
            DECL_NORM(8)  DECL_NORM(9)  DECL_NORM(10) DECL_NORM(11)
            DECL_NORM(12) DECL_NORM(13) DECL_NORM(14) DECL_NORM(15)
            SAMPLER(sampler_Normal0);

            CBUFFER_START(UnityPerMaterial)
                float4 _LayerU[16];
                float4 _LayerV[16];
                float4 _LayerMode[16];   // x=1: old-format global color_tex uses whole-map UV
                float4 _LayerMap[16];    // x=rotationRad, zw=Blender Mapping scale xy
                float4 _ChunkUV_ST;      // xy=1/numChunks, zw=(chunkCoord-boundsMin)/numChunks
                float4 _TerrainGlobal;   // x=minWorldX, y=minWorldZ, z=sizeX, w=sizeZ
                float  _NumLayers;
                float  _NumBlends;
                float  _NewBlendFormat;
                float  _UseGlobalMap;
                float  _Brightness;
                float  _BumpScale;
                float  _UseNormalMaps;
            CBUFFER_END

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
                float4 tangentOS  : TANGENT;
                float2 uv         : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionHCS : SV_POSITION;
                float3 positionWS  : TEXCOORD0;
                float3 normalWS    : TEXCOORD1;
                float2 uv          : TEXCOORD2;
                float3 tangentWS   : TEXCOORD3;
                float3 bitangentWS : TEXCOORD4;
            };

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                VertexPositionInputs p = GetVertexPositionInputs(IN.positionOS.xyz);
                OUT.positionHCS  = p.positionCS;
                OUT.positionWS   = p.positionWS;
                OUT.normalWS     = TransformObjectToWorldNormal(IN.normalOS);
                OUT.tangentWS    = TransformObjectToWorldDir(IN.tangentOS.xyz);
                OUT.bitangentWS  = cross(OUT.normalWS, OUT.tangentWS) * IN.tangentOS.w;
                OUT.uv = IN.uv;
                return OUT;
            }

            float2 WrapWoTLayerUV(float2 uv)
            {
                const float mn   = 0.0625;
                const float mx   = 0.9375;
                const float span = mx - mn;
                return mn + frac((uv - mn) / span) * span;
            }

            float2 ChunkMapUV(float2 localUV)
            {
                return localUV * _ChunkUV_ST.xy + _ChunkUV_ST.zw;
            }

            float2 LayerUV(int idx, float3 positionWS, float2 localUV)
            {
                if (_LayerMode[idx].x > 0.5)
                    return ChunkMapUV(localUV);

                float2 p = positionWS.xz;
                if (_NewBlendFormat > 0.5)
                {
                    float numX       = rcp(_ChunkUV_ST.x);
                    float chunkSizeX = _TerrainGlobal.z / max(numX, 1.0);
                    float minChunkX  = _TerrainGlobal.x / max(chunkSizeX, 1e-5);
                    float maxChunkX  = minChunkX + numX - 1.0;
                    float chunkX     = round(_ChunkUV_ST.z * numX + minChunkX);
                    float mirroredX  = minChunkX + maxChunkX - chunkX;
                    p.x = (mirroredX + localUV.x) * chunkSizeX;
                }
                float a  = _LayerMap[idx].x;
                float ca = cos(a), sa = sin(a);
                float2 r = float2(p.x * ca - p.y * sa, p.x * sa + p.y * ca);
                return WrapWoTLayerUV(r / _LayerMap[idx].zw);
            }

            float4 SampleBlend(int idx, float2 uv)
            {
                #define SAMP_B(n) if (idx == n) return SAMPLE_TEXTURE2D(_Blend##n, sampler_Blend0, uv);
                SAMP_B(0) SAMP_B(1) SAMP_B(2) SAMP_B(3)
                SAMP_B(4) SAMP_B(5) SAMP_B(6) SAMP_B(7)
                return float4(0,0,0,0);
                #undef SAMP_B
            }

            float3 SampleSplat(int idx, float3 positionWS, float2 localUV)
            {
                float2 uv = LayerUV(idx, positionWS, localUV);
                #define SAMP_S(n) if (idx == n) return SAMPLE_TEXTURE2D(_Splat##n, sampler_Splat0, uv).rgb;
                SAMP_S(0)  SAMP_S(1)  SAMP_S(2)  SAMP_S(3)
                SAMP_S(4)  SAMP_S(5)  SAMP_S(6)  SAMP_S(7)
                SAMP_S(8)  SAMP_S(9)  SAMP_S(10) SAMP_S(11)
                SAMP_S(12) SAMP_S(13) SAMP_S(14) SAMP_S(15)
                return float3(1,1,1);
                #undef SAMP_S
            }

            // Returns a tangent-space normal for a given layer, blended by weight.
            float3 SampleNormal(int idx, float3 positionWS, float2 localUV)
            {
                float2 uv = LayerUV(idx, positionWS, localUV);
                #define SAMP_N(n) if (idx == n) return UnpackNormalScale(SAMPLE_TEXTURE2D(_Normal##n, sampler_Normal0, uv), _BumpScale);
                SAMP_N(0)  SAMP_N(1)  SAMP_N(2)  SAMP_N(3)
                SAMP_N(4)  SAMP_N(5)  SAMP_N(6)  SAMP_N(7)
                SAMP_N(8)  SAMP_N(9)  SAMP_N(10) SAMP_N(11)
                SAMP_N(12) SAMP_N(13) SAMP_N(14) SAMP_N(15)
                return float3(0, 0, 1); // flat
                #undef SAMP_N
            }

            float LayerScalarWeightNewFormat(int layerIdx, float2 blendUV)
            {
                int blendIdx = layerIdx / 2;
                if (blendIdx >= (int)_NumBlends) return 0.0;
                float4 b = SampleBlend(blendIdx, blendUV);
                return (layerIdx & 1) == 0 ? b.a : b.g;
            }

            half4 frag(Varyings IN) : SV_Target
            {
                // Blender Mapping node for blend textures uses Scale=(1,-1,1).
                float2 blendUV = float2(IN.uv.x, 1.0 - IN.uv.y);

                int n = min((int)_NumLayers, 16);
                float3 albedo  = 0;
                float3 tsNormal = float3(0, 0, 0);
                float  wsum   = 0;

                if (_NewBlendFormat > 0.5)
                {
                    [loop] for (int i = 0; i < 16; i++)
                    {
                        if (i >= n) break;
                        float w = LayerScalarWeightNewFormat(i, blendUV);
                        albedo  += SampleSplat(i, IN.positionWS, IN.uv) * w;
                        if (_UseNormalMaps > 0.5)
                            tsNormal += SampleNormal(i, IN.positionWS, IN.uv) * w;
                        wsum += w;
                    }
                }
                else
                {
                    [loop] for (int i = 0; i < 16; i++)
                    {
                        if (i >= n || i >= (int)_NumBlends) break;
                        float3 w = SampleBlend(i, blendUV).rgb;
                        albedo  += SampleSplat(i, IN.positionWS, IN.uv) * w;
                        if (_UseNormalMaps > 0.5)
                            tsNormal += SampleNormal(i, IN.positionWS, IN.uv) * max(w.r, max(w.g, w.b));
                        wsum += max(w.r, max(w.g, w.b));
                    }
                }

                if (wsum <= 1e-4)
                {
                    albedo   = SampleSplat(0, IN.positionWS, IN.uv);
                    tsNormal = _UseNormalMaps > 0.5 ? SampleNormal(0, IN.positionWS, IN.uv) : float3(0, 0, 1);
                }

                if (_UseGlobalMap > 0.5)
                {
                    float2 guv = ChunkMapUV(IN.uv);
                    albedo *= SAMPLE_TEXTURE2D(_GlobalMap, sampler_Blend0, saturate(guv)).rgb;
                }

                // Reconstruct world-space normal
                float3 nWS;
                if (_UseNormalMaps > 0.5 && dot(tsNormal, tsNormal) > 1e-6)
                {
                    tsNormal = normalize(tsNormal);
                    nWS = normalize(
                        tsNormal.x * normalize(IN.tangentWS) +
                        tsNormal.y * normalize(IN.bitangentWS) +
                        tsNormal.z * normalize(IN.normalWS));
                }
                else
                {
                    nWS = normalize(IN.normalWS);
                }

                Light mainLight = GetMainLight();
                float ndotl = saturate(dot(nWS, mainLight.direction));
                float3 lit  = albedo * (mainLight.color * ndotl + unity_AmbientSky.rgb + 0.20) * _Brightness;
                return half4(lit, 1);
            }
            ENDHLSL
        }

        Pass
        {
            Name "ShadowCaster"
            Tags { "LightMode"="ShadowCaster" }
            ZWrite On ZTest LEqual ColorMask 0
            Cull Back

            HLSLPROGRAM
            #pragma vertex shadowVert
            #pragma fragment shadowFrag
            #pragma target 3.0

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/ShadowCasterPass.hlsl"
            ENDHLSL
        }
    }

    Fallback "Universal Render Pipeline/Lit"
}
