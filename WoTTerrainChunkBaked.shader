// Simple shader for baked per-cdata terrain chunk textures.
// Each mesh chunk uses UV0 0..1 and a unique baked albedo texture.
// Normal map support: assign _NormalMap to enable tangent-space bump mapping.
Shader "WoT/TerrainChunkBaked"
{
    Properties
    {
        _MainTex  ("Chunk Albedo", 2D)  = "white" {}
        _Brightness ("Brightness", Float) = 1

        // UV correction for already baked chunk textures.
        // 0=None, 1=90 CW, 2=180, 3=270 CW. Default 2 means rotate baked texture by 180 degrees.
        [Enum(None,0,Rotate 90 CW,1,Rotate 180,2,Rotate 270 CW,3)] _UVRotation ("Baked UV Rotation", Float) = 2
        [Toggle] _UVFlipX ("Flip U / X", Float) = 0
        [Toggle] _UVFlipY ("Flip V / Y", Float) = 0

        // Normal map
        [Normal] _NormalMap ("Normal Map", 2D) = "bump" {}
        _BumpScale ("Normal Scale", Float) = 1.0
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
            #pragma target 3.0
            #pragma shader_feature_local _NORMALMAP

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            TEXTURE2D(_MainTex);   SAMPLER(sampler_MainTex);
            TEXTURE2D(_NormalMap); SAMPLER(sampler_NormalMap);

            CBUFFER_START(UnityPerMaterial)
                float4 _MainTex_ST;
                float4 _NormalMap_ST;
                float  _Brightness;
                float  _UVRotation;
                float  _UVFlipX;
                float  _UVFlipY;
                float  _BumpScale;
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
                float3 normalWS    : TEXCOORD0;
                float2 uv          : TEXCOORD1;
                float3 tangentWS   : TEXCOORD2;
                float3 bitangentWS : TEXCOORD3;
            };

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                VertexPositionInputs p = GetVertexPositionInputs(IN.positionOS.xyz);
                OUT.positionHCS  = p.positionCS;
                OUT.normalWS     = TransformObjectToWorldNormal(IN.normalOS);
                OUT.tangentWS    = TransformObjectToWorldDir(IN.tangentOS.xyz);
                OUT.bitangentWS  = cross(OUT.normalWS, OUT.tangentWS) * IN.tangentOS.w;
                // Keep raw mesh UV here; texture correction is done in the fragment
                // shader so changing material values updates instantly in the Scene view.
                OUT.uv = IN.uv;
                return OUT;
            }

            float2 RotateBakedUV(float2 uv)
            {
                if (_UVRotation > 0.5 && _UVRotation < 1.5)
                    uv = float2(1.0 - uv.y, uv.x);
                else if (_UVRotation >= 1.5 && _UVRotation < 2.5)
                    uv = float2(1.0 - uv.x, 1.0 - uv.y);
                else if (_UVRotation >= 2.5)
                    uv = float2(uv.y, 1.0 - uv.x);

                if (_UVFlipX > 0.5) uv.x = 1.0 - uv.x;
                if (_UVFlipY > 0.5) uv.y = 1.0 - uv.y;
                return uv;
            }

            float3 ResolveNormal(Varyings IN)
            {
#if _NORMALMAP
                float2 nmUV = TRANSFORM_TEX(IN.uv, _NormalMap);
                float4 nmSample = SAMPLE_TEXTURE2D(_NormalMap, sampler_NormalMap, nmUV);
                float3 tsNormal = UnpackNormalScale(nmSample, _BumpScale);
                return normalize(
                    tsNormal.x * normalize(IN.tangentWS) +
                    tsNormal.y * normalize(IN.bitangentWS) +
                    tsNormal.z * normalize(IN.normalWS));
#else
                return normalize(IN.normalWS);
#endif
            }

            half4 frag(Varyings IN) : SV_Target
            {
                float2 uv = RotateBakedUV(IN.uv);
                uv = TRANSFORM_TEX(uv, _MainTex);
                float3 albedo = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv).rgb;

                float3 nWS  = ResolveNormal(IN);
                Light mainLight = GetMainLight();
                float ndotl = saturate(dot(nWS, mainLight.direction));
                float3 color = albedo * (mainLight.color * ndotl + unity_AmbientSky.rgb + 0.20) * _Brightness;
                return half4(color, 1);
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
