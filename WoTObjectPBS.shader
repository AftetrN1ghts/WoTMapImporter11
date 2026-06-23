// WoT static-object preview shader.
// Supports the material cases used by map objects in the Blender addon:
// 0 - simple diffuseMap
// 1 - PBS_tiled.fx (3 tiled albedoHeight textures + blendMask on uv2)
// 2 - PBS_tiled_atlas.fx with atlasAlbedoHeight as one DDS atlas
// 3 - PBS_tiled_atlas.fx with atlasAlbedoHeight .atlas metadata (tiles loaded separately)
//
// Normal map support:
//   _NormalMap / _BumpMap are sampled and applied as a tangent-space normal.
//   If neither is assigned the mesh normal is used as-is (same as before).
Shader "WoT/ObjectPBS"
{
    Properties
    {
        _MainTex      ("Diffuse",             2D)      = "white"  {}
        _Tile0        ("Tile 0",              2D)      = "white"  {}
        _Tile1        ("Tile 1",              2D)      = "white"  {}
        _Tile2        ("Tile 2",              2D)      = "white"  {}
        _BlendMask    ("Blend Mask",          2D)      = "black"  {}
        _AtlasTex     ("Atlas Albedo/Height", 2D)      = "white"  {}
        _AtlasBlend   ("Atlas Blend",         2D)      = "black"  {}

        // Normal map – same slot name as URP Lit so material inspector
        // shows a proper "Normal Map" preview label.
        [Normal] _NormalMap ("Normal Map", 2D) = "bump" {}
        _BumpScale    ("Normal Scale",        Float)   = 1.0

        _ObjectColor  ("Object Color",        Color)   = (1,1,1,1)
        _Tile0Tint    ("Tile 0 Tint",         Vector)  = (1,1,1,1)
        _Tile1Tint    ("Tile 1 Tint",         Vector)  = (1,1,1,1)
        _Tile2Tint    ("Tile 2 Tint",         Vector)  = (1,1,1,1)
        _AtlasIndexes ("Atlas Indexes",       Vector)  = (0,1,2,3)
        _AtlasGrid    ("Atlas Grid",          Vector)  = (1,1,0,0)
        _UseUv2Blend  ("Use UV2 For Blend",   Float)   = 1
        _Mode         ("Mode",                Float)   = 0
        _Brightness   ("Preview Brightness",  Float)   = 1
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

            // Enable the normal-map variant keyword so Unity knows this
            // material needs tangents.
            #pragma shader_feature_local _NORMALMAP

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            TEXTURE2D(_MainTex);   SAMPLER(sampler_MainTex);
            TEXTURE2D(_Tile0);     TEXTURE2D(_Tile1); TEXTURE2D(_Tile2);
            TEXTURE2D(_BlendMask);
            TEXTURE2D(_AtlasTex);  TEXTURE2D(_AtlasBlend);
            TEXTURE2D(_NormalMap); SAMPLER(sampler_NormalMap);

            CBUFFER_START(UnityPerMaterial)
                float4 _MainTex_ST;
                float4 _Tile0_ST;
                float4 _Tile1_ST;
                float4 _Tile2_ST;
                float4 _BlendMask_ST;
                float4 _AtlasTex_ST;
                float4 _AtlasBlend_ST;
                float4 _NormalMap_ST;
                float4 _ObjectColor;
                float4 _Tile0Tint;
                float4 _Tile1Tint;
                float4 _Tile2Tint;
                float4 _AtlasIndexes;
                float4 _AtlasGrid;
                float  _UseUv2Blend;
                float  _Mode;
                float  _Brightness;
                float  _BumpScale;
            CBUFFER_END

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
                float4 tangentOS  : TANGENT;
                float2 uv         : TEXCOORD0;
                float2 uv2        : TEXCOORD1;
            };

            struct Varyings
            {
                float4 positionHCS : SV_POSITION;
                float3 normalWS    : TEXCOORD0;
                float2 uv          : TEXCOORD1;
                float2 uv2         : TEXCOORD2;
                float3 tangentWS   : TEXCOORD3;
                float3 bitangentWS : TEXCOORD4;
            };

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                VertexPositionInputs p = GetVertexPositionInputs(IN.positionOS.xyz);
                OUT.positionHCS  = p.positionCS;
                OUT.normalWS     = TransformObjectToWorldNormal(IN.normalOS);
                OUT.tangentWS    = TransformObjectToWorldDir(IN.tangentOS.xyz);
                OUT.bitangentWS  = cross(OUT.normalWS, OUT.tangentWS) * IN.tangentOS.w;
                OUT.uv  = IN.uv;
                OUT.uv2 = IN.uv2;
                return OUT;
            }

            // Reconstruct the per-pixel world normal from the normal map sample.
            float3 ApplyNormalMap(Varyings IN, float3 defaultNormalWS)
            {
#if _NORMALMAP
                float2 nmUV = TRANSFORM_TEX(IN.uv, _NormalMap);
                float4 nmSample = SAMPLE_TEXTURE2D(_NormalMap, sampler_NormalMap, nmUV);
                // UnpackNormalScale works with both DXT5nm (AG) and RGB normal maps.
                float3 tsNormal = UnpackNormalScale(nmSample, _BumpScale);
                // TBN matrix: columns are tangent, bitangent, normal in world space.
                float3 N = normalize(
                    tsNormal.x * normalize(IN.tangentWS) +
                    tsNormal.y * normalize(IN.bitangentWS) +
                    tsNormal.z * normalize(IN.normalWS));
                return N;
#else
                return normalize(defaultNormalWS);
#endif
            }

            float2 WrapWoTUV(float2 uv)
            {
                const float mn   = 0.0625;
                const float mx   = 0.9375;
                const float span = mx - mn;
                return mn + frac((uv - mn) / span) * span;
            }

            float2 AtlasCellUV(float index, float2 localUV)
            {
                float cols = max(_AtlasGrid.x, 1.0);
                float rows = max(_AtlasGrid.y, 1.0);
                float idx  = max(floor(index + 0.5), 0.0);
                float y    = floor(idx / cols);
                float x    = idx - y * cols;
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
                return _UseUv2Blend > 0.5 ? IN.uv2 : IN.uv;
            }

            float4 SampleAtlasBlend(float2 blendUv)
            {
                return SAMPLE_TEXTURE2D(_AtlasBlend, sampler_MainTex, AtlasCellUV(_AtlasIndexes.w, blendUv));
            }

            float3 Shade(float3 albedo, float3 normalWS)
            {
                float3 n    = normalize(normalWS);
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
                    float2 tileUV  = IN.uv;
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
                    float4 blend  = SampleAtlasBlend(BlendUV(IN));
                    float w0 = blend.r;
                    float w1 = blend.g;
                    float w2 = saturate(1.0 - w0 - w1);
                    float3 c0 = SAMPLE_TEXTURE2D(_Tile0, sampler_MainTex, TRANSFORM_TEX(tileUV, _Tile0)).rgb * _Tile0Tint.rgb;
                    float3 c1 = SAMPLE_TEXTURE2D(_Tile1, sampler_MainTex, TRANSFORM_TEX(tileUV, _Tile1)).rgb * _Tile1Tint.rgb;
                    float3 c2 = SAMPLE_TEXTURE2D(_Tile2, sampler_MainTex, TRANSFORM_TEX(tileUV, _Tile2)).rgb * _Tile2Tint.rgb;
                    albedo = c0 * w0 + c1 * w1 + c2 * w2;
                    albedo *= _ObjectColor.rgb;
                }

                // Reconstruct final normal (mesh normal or normal-mapped)
                float3 finalNormal = ApplyNormalMap(IN, IN.normalWS);

                return half4(Shade(albedo, finalNormal), _ObjectColor.a);
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
