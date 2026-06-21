// WoT static-object preview shader.
// Supports the material cases used by map objects in the Blender addon:
//   0 - simple diffuseMap
//   1 - PBS_tiled.fx (3 tiled albedoHeight textures + blendMask on uv2)
//   2 - PBS_tiled_atlas.fx with atlasAlbedoHeight as one DDS atlas
//   3 - PBS_tiled_atlas.fx with atlasAlbedoHeight .atlas metadata (tiles loaded separately)
Shader "WoT/ObjectPBS"
{
    Properties
    {
        _MainTex ("Diffuse", 2D) = "white" {}
        _Tile0 ("Tile 0", 2D) = "white" {}
        _Tile1 ("Tile 1", 2D) = "white" {}
        _Tile2 ("Tile 2", 2D) = "white" {}
        _BlendMask ("Blend Mask", 2D) = "black" {}
        _AtlasTex ("Atlas Albedo/Height", 2D) = "white" {}
        _AtlasBlend ("Atlas Blend", 2D) = "black" {}
        _ObjectColor ("Object Color", Color) = (1,1,1,1)
        _Tile0Tint ("Tile 0 Tint", Vector) = (1,1,1,1)
        _Tile1Tint ("Tile 1 Tint", Vector) = (1,1,1,1)
        _Tile2Tint ("Tile 2 Tint", Vector) = (1,1,1,1)
        _AtlasIndexes ("Atlas Indexes", Vector) = (0,1,2,3)
        _AtlasGrid ("Atlas Grid", Vector) = (1,1,0,0)
        _UseUv2Blend ("Use UV2 For Blend", Float) = 1
        _Mode ("Mode", Float) = 0
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

            TEXTURE2D(_MainTex);    SAMPLER(sampler_MainTex);
            TEXTURE2D(_Tile0);      TEXTURE2D(_Tile1);      TEXTURE2D(_Tile2);
            TEXTURE2D(_BlendMask);
            TEXTURE2D(_AtlasTex);   TEXTURE2D(_AtlasBlend);

            CBUFFER_START(UnityPerMaterial)
                float4 _MainTex_ST;
                float4 _Tile0_ST;
                float4 _Tile1_ST;
                float4 _Tile2_ST;
                float4 _BlendMask_ST;
                float4 _AtlasTex_ST;
                float4 _AtlasBlend_ST;
                float4 _ObjectColor;
                float4 _Tile0Tint;
                float4 _Tile1Tint;
                float4 _Tile2Tint;
                float4 _AtlasIndexes;
                float4 _AtlasGrid;
                float _UseUv2Blend;
                float _Mode;
                float _Brightness;
            CBUFFER_END

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
                float2 uv         : TEXCOORD0;
                float2 uv2        : TEXCOORD1;
            };

            struct Varyings
            {
                float4 positionHCS : SV_POSITION;
                float3 normalWS    : TEXCOORD0;
                float2 uv          : TEXCOORD1;
                float2 uv2         : TEXCOORD2;
            };

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                VertexPositionInputs p = GetVertexPositionInputs(IN.positionOS.xyz);
                OUT.positionHCS = p.positionCS;
                OUT.normalWS = TransformObjectToWorldNormal(IN.normalOS);
                OUT.uv = IN.uv;
                OUT.uv2 = IN.uv2;
                return OUT;
            }

            float2 WrapWoTUV(float2 uv)
            {
                // Same WRAP node values used by Simi4's PBS_tiled_atlas material:
                // max=(0.9375,0.9375), min=(0.0625,0.0625).  This keeps sampling
                // inside the padded atlas/tile interior and avoids neighbour bleed.
                const float mn = 0.0625;
                const float mx = 0.9375;
                const float span = mx - mn;
                return mn + frac((uv - mn) / span) * span;
            }

            float2 AtlasCellUV(float index, float2 localUV)
            {
                float cols = max(_AtlasGrid.x, 1.0);
                float rows = max(_AtlasGrid.y, 1.0);
                float idx = max(floor(index + 0.5), 0.0);
                float y = floor(idx / cols);
                float x = idx - y * cols;
                // WoT/Blender use top-left logical atlas rows; Unity UV origin is bottom-left.
                y = rows - 1.0 - y;
                return (float2(x, y) + localUV) / float2(cols, rows);
            }

            float3 SampleAtlasTile(float index, float2 uv)
            {
                float2 local = WrapWoTUV(uv);
                return SAMPLE_TEXTURE2D(_AtlasTex, sampler_MainTex, AtlasCellUV(index, local)).rgb;
            }

            float2 BlendUV(Varyings IN)
            {
                // Correct WoT PBS_tiled/PBS_tiled_atlas materials use UV2 for the
                // blend mask.  If a particular primitive has no useful UV2 section,
                // fall back to UV1 instead of sampling one constant point over the
                // whole object/map.
                return _UseUv2Blend > 0.5 ? IN.uv2 : IN.uv;
            }

            float4 SampleAtlasBlend(float2 blendUv)
            {
                return SAMPLE_TEXTURE2D(_AtlasBlend, sampler_MainTex, AtlasCellUV(_AtlasIndexes.w, blendUv));
            }

            float3 Shade(float3 albedo, float3 normalWS)
            {
                float3 n = normalize(normalWS);
                Light mainLight = GetMainLight();
                float ndotl = saturate(dot(n, mainLight.direction));
                float3 ambient = SampleSH(n);
                return albedo * (mainLight.color * ndotl + ambient + 0.15) * _Brightness;
            }

            half4 frag(Varyings IN) : SV_Target
            {
                float2 uv = TRANSFORM_TEX(IN.uv, _MainTex);
                float3 albedo;

                if (_Mode < 0.5)
                {
                    albedo = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv).rgb * _ObjectColor.rgb;
                }
                else if (_Mode < 1.5)
                {
                    // Simi4's PBS_tiled node tree samples tile textures from the
                    // ordinary UV channel; only the blend mask uses UV2. Do not wrap
                    // this case, otherwise many large map props get the tile pattern
                    // smeared/repeated across the whole object.
                    float2 tileUV = IN.uv;
                    float2 blendUV = BlendUV(IN);
                    float4 blend = SAMPLE_TEXTURE2D(_BlendMask, sampler_MainTex, TRANSFORM_TEX(blendUV, _BlendMask));
                    float3 c0 = SAMPLE_TEXTURE2D(_Tile0, sampler_MainTex, TRANSFORM_TEX(tileUV, _Tile0)).rgb * _Tile0Tint.rgb;
                    float3 c1 = SAMPLE_TEXTURE2D(_Tile1, sampler_MainTex, TRANSFORM_TEX(tileUV, _Tile1)).rgb * _Tile1Tint.rgb;
                    float3 c2 = SAMPLE_TEXTURE2D(_Tile2, sampler_MainTex, TRANSFORM_TEX(tileUV, _Tile2)).rgb * _Tile2Tint.rgb;
                    albedo = c0 * blend.r + c1 * blend.g + c2 * blend.b;
                    if (dot(blend.rgb, float3(1.0, 1.0, 1.0)) <= 1e-4) albedo = c0;
                    albedo *= _ObjectColor.rgb;
                }
                else if (_Mode < 2.5)
                {
                    float4 blend = SampleAtlasBlend(BlendUV(IN));
                    float w0 = blend.r;
                    float w1 = blend.g;
                    float w2 = saturate(1.0 - w0 - w1);
                    float3 c0 = SampleAtlasTile(_AtlasIndexes.x, IN.uv) * _Tile0Tint.rgb;
                    float3 c1 = SampleAtlasTile(_AtlasIndexes.y, IN.uv) * _Tile1Tint.rgb;
                    float3 c2 = SampleAtlasTile(_AtlasIndexes.z, IN.uv) * _Tile2Tint.rgb;
                    albedo = c0 * w0 + c1 * w1 + c2 * w2;
                    albedo *= _ObjectColor.rgb;
                }
                else
                {
                    float2 tileUV = WrapWoTUV(IN.uv);
                    float4 blend = SampleAtlasBlend(BlendUV(IN));
                    float w0 = blend.r;
                    float w1 = blend.g;
                    float w2 = saturate(1.0 - w0 - w1);
                    float3 c0 = SAMPLE_TEXTURE2D(_Tile0, sampler_MainTex, TRANSFORM_TEX(tileUV, _Tile0)).rgb * _Tile0Tint.rgb;
                    float3 c1 = SAMPLE_TEXTURE2D(_Tile1, sampler_MainTex, TRANSFORM_TEX(tileUV, _Tile1)).rgb * _Tile1Tint.rgb;
                    float3 c2 = SAMPLE_TEXTURE2D(_Tile2, sampler_MainTex, TRANSFORM_TEX(tileUV, _Tile2)).rgb * _Tile2Tint.rgb;
                    albedo = c0 * w0 + c1 * w1 + c2 * w2;
                    albedo *= _ObjectColor.rgb;
                }

                return half4(Shade(albedo, IN.normalWS), _ObjectColor.a);
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
            V shadowVert(A IN) { V OUT; OUT.positionHCS = TransformObjectToHClip(IN.positionOS.xyz); return OUT; }
            half4 shadowFrag(V IN) : SV_Target { return 0; }
            ENDHLSL
        }
    }

    Fallback "Universal Render Pipeline/Lit"
}
