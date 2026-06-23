Shader "WoT/TerrainChunkBaked"
{
    Properties
    {
        _MainTex    ("Chunk Albedo", 2D)   = "white" {}
        _Brightness ("Brightness",  Float) = 1
        [Enum(None,0,Rotate 90 CW,1,Rotate 180,2,Rotate 270 CW,3)]
        _UVRotation ("Baked UV Rotation", Float) = 2
        [Toggle] _UVFlipX ("Flip U", Float) = 0
        [Toggle] _UVFlipY ("Flip V", Float) = 0
        [Normal] _NormalMap ("Normal Map", 2D) = "bump" {}
        _BumpScale  ("Normal Scale", Float) = 1.0
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
            
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile_fragment _ _SHADOWS_SOFT _SHADOWS_SOFT_LOW
            #pragma multi_compile _ SHADOWS_SHADOWMASK
            #pragma multi_compile_fragment _ _SHADOW_CASCADES_BLEND
            #pragma multi_compile_instancing
            #pragma multi_compile_fog

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
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };
            struct Varyings
            {
                float4 positionHCS : SV_POSITION;
                float3 positionWS  : TEXCOORD0;
                float3 normalWS    : TEXCOORD1;
                float2 uv          : TEXCOORD2;
                float3 tangentWS   : TEXCOORD3;
                float3 bitangentWS : TEXCOORD4;
                float  fogFactor   : TEXCOORD5;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                UNITY_SETUP_INSTANCE_ID(IN);
                UNITY_TRANSFER_INSTANCE_ID(IN, OUT);
                VertexPositionInputs posInputs = GetVertexPositionInputs(IN.positionOS.xyz);
                VertexNormalInputs   nrmInputs = GetVertexNormalInputs(IN.normalOS, IN.tangentOS);
                OUT.positionHCS  = posInputs.positionCS;
                OUT.positionWS   = posInputs.positionWS;
                OUT.fogFactor    = ComputeFogFactor(posInputs.positionCS.z);
                OUT.normalWS     = nrmInputs.normalWS;
                OUT.tangentWS    = nrmInputs.tangentWS;
                OUT.bitangentWS  = nrmInputs.bitangentWS;
                OUT.uv           = IN.uv;
                return OUT;
            }

            float2 RotateBakedUV(float2 uv)
            {
                if      (_UVRotation > 0.5 && _UVRotation < 1.5) uv = float2(1.0 - uv.y, uv.x);
                else if (_UVRotation >= 1.5 && _UVRotation < 2.5) uv = float2(1.0 - uv.x, 1.0 - uv.y);
                else if (_UVRotation >= 2.5)                       uv = float2(uv.y, 1.0 - uv.x);
                if (_UVFlipX > 0.5) uv.x = 1.0 - uv.x;
                if (_UVFlipY > 0.5) uv.y = 1.0 - uv.y;
                return uv;
            }

            float3 ResolveNormal(Varyings IN)
            {
                // Всегда сэмплируем normal map (bump = flat normal если не назначен)
                float4 s  = SAMPLE_TEXTURE2D(_NormalMap, sampler_NormalMap, TRANSFORM_TEX(IN.uv, _NormalMap));
                float3 ts = UnpackNormalScale(s, _BumpScale);
                return normalize(ts.x * IN.tangentWS + ts.y * IN.bitangentWS + ts.z * IN.normalWS);
            }

            half4 frag(Varyings IN) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(IN);
                float2 uv    = TRANSFORM_TEX(RotateBakedUV(IN.uv), _MainTex);
                float3 albedo = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv).rgb;
                float3 nWS   = ResolveNormal(IN);
                // Вычисляем shadowCoord в fragment — точный каскад без видимых кругов
                #if defined(_MAIN_LIGHT_SHADOWS_SCREEN)
                    float4 shadowCoord = ComputeScreenPos(TransformWorldToHClip(IN.positionWS));
                #elif defined(_MAIN_LIGHT_SHADOWS) || defined(_MAIN_LIGHT_SHADOWS_CASCADE)
                    float4 shadowCoord = TransformWorldToShadowCoord(IN.positionWS);
                #else
                    float4 shadowCoord = float4(0,0,0,0);
                #endif
                Light mainLight = GetMainLight(shadowCoord);
                float ndotl = saturate(dot(nWS, mainLight.direction));
                float3 lit  = albedo * (mainLight.color * ndotl * mainLight.shadowAttenuation
                                      + unity_AmbientSky.rgb + 0.20) * _Brightness;
                lit = MixFog(lit, IN.fogFactor);
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
            #pragma vertex ShadowVert
            #pragma fragment ShadowFrag
            #pragma target 3.0
            #pragma multi_compile_instancing
            #pragma multi_compile_vertex _ _CASTING_PUNCTUAL_LIGHT_SHADOW

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            // Bias значения — стандартные для URP
            // Depth bias: отодвигает shadow map от поверхности
            // Normal bias: смещает вдоль нормали чтобы убрать "сферу" вокруг объектов
            float3 _LightDirection;
            float3 _LightPosition;

            struct ShadowAttr
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };
            struct ShadowVary
            {
                float4 positionCS : SV_POSITION;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            float3 ApplyShadowBiasWS(float3 posWS, float3 normalWS, float3 lightDir)
            {
                // Normal bias: сдвиг вдоль нормали пропорционально углу света
                // Убирает "тёмную сферу" вокруг камеры и self-shadowing
                float normalBias = 0.02;
                float depthBias  = 0.001;
                float invNdotL   = 1.0 - saturate(dot(normalWS, lightDir));
                posWS += normalWS * invNdotL * normalBias;
                posWS -= lightDir * depthBias;
                return posWS;
            }

            ShadowVary ShadowVert(ShadowAttr IN)
            {
                ShadowVary OUT;
                UNITY_SETUP_INSTANCE_ID(IN);
                UNITY_TRANSFER_INSTANCE_ID(IN, OUT);

                float3 posWS = TransformObjectToWorld(IN.positionOS.xyz);
                float3 nrmWS = TransformObjectToWorldNormal(IN.normalOS);

            #if _CASTING_PUNCTUAL_LIGHT_SHADOW
                float3 lightDir = normalize(_LightPosition - posWS);
            #else
                float3 lightDir = _LightDirection;
            #endif

                posWS = ApplyShadowBiasWS(posWS, nrmWS, lightDir);

                float4 posCS = TransformWorldToHClip(posWS);

                // Зажимаем z чтобы убрать пропадание теней на near plane
            #if UNITY_REVERSED_Z
                posCS.z = min(posCS.z, posCS.w * UNITY_NEAR_CLIP_VALUE);
            #else
                posCS.z = max(posCS.z, posCS.w * UNITY_NEAR_CLIP_VALUE);
            #endif

                OUT.positionCS = posCS;
                return OUT;
            }

            half4 ShadowFrag(ShadowVary IN) : SV_Target { return 0; }
            ENDHLSL
        }
    }

    Fallback "Universal Render Pipeline/Lit"
}
