Shader "Lit/MyBRDF"
{
    Properties
    {
        _BaseMap ("Albedo", 2D) = "white" {}
        _BumpMap("NormalMap", 2D) = "bump" {}
        _BrdfLUT("LUT", 2D) = "white" {}
        _BaseColor ("BaseColor", Color) = (1,1,1,1)
        _Roughness("Roughness", Range(0, 1)) = 0.5
        _Metalness("Metalness", Range(0, 1)) = 0.5
    }
    SubShader
    {
        Tags { "RenderType"="Opaque" }
        LOD 100

        Pass
        {
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            // make fog work
            #pragma multi_compile_fog
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            struct appdata
            {
                float4 positionOS : POSITION;
                float2 uv : TEXCOORD0;
                float3 normalOS: NORMAL;
                float4 tangentOS: TANGENT;
            };

            struct v2f
            {
                float2 uv : TEXCOORD0;
                float4 positionCS : SV_POSITION;
                float3 normalWS : TEXCOORD1;
                float4 tangentWS : TEXCOORD2;    // xyz: tangent, w: sign
            };

            sampler2D _BaseMap;
            sampler2D _BrdfLUT;
            TEXTURE2D(_BumpMap);
            SAMPLER(sampler_BumpMap);
            CBUFFER_START(UnityPerMaterial)
            float4 _BaseMap_ST;
            float _Roughness;
            float _Metalness;
            half4 _BaseColor;
            CBUFFER_END

            float D_Function(float NdotH, float roughness)
            {
                float a2 = roughness * roughness;
                float NdotH2 = NdotH * NdotH;

                float nom = a2;
                float denom = NdotH2 * (a2 - 1.0) + 1.0;
                denom = denom * denom * PI;
                return nom / denom;
            }

            float G_section(float dot, float k)
            {
                float nom = dot;
                float denom = dot * (1.0 - k) + k;
                return nom / denom;
            }
            // direct light k = pow(1 + roughness, 2) / 8
            // indirect light = pow(roughness, 2) / 2
            float G_Function(float NdotL, float NdotV, float roughness)
            {
                float k = pow(1.0 + roughness, 2.0) / 8.0;
                float Gnl = G_section(NdotL, k);
                float Gnv = G_section(NdotV, k);
                return Gnl * Gnv;
            }

            float3 F_Function(float HdotL, float3 F0)
            {
                float fre = exp2((-5.55473 * HdotL - 6.98316) * HdotL);
                // return lerp(fre, 1, F0);
                return F0 + (1 - F0) * fre;
            }

            real3 SH_IndirectDiffuse(float3 normalWS)
            {
                real4 SHCoefficients[7];
                SHCoefficients[0] = unity_SHAr;
                SHCoefficients[1] = unity_SHAg;
                SHCoefficients[2] = unity_SHAb;
                SHCoefficients[3] = unity_SHBr;
                SHCoefficients[4] = unity_SHBg;
                SHCoefficients[5] = unity_SHBb;
                SHCoefficients[6] = unity_SHC;
                float3 indirectDiffuseLighting = SampleSH9(SHCoefficients, normalWS);
                return max(0, indirectDiffuseLighting);
            }

            real3 GetIndirectKs(float NdotV, float3 F0, float roughness)
            {
                float fre = exp2((-5.55473 * NdotV - 6.98316) * NdotV);
                return lerp(fre, 1, max(1.0 - roughness, F0));
            }

            real3 SampleIndirectCube(float3 normalWS, float3 viewWS, float roughness, float AO)
            {
                float3 reflectDirectionWS = reflect(-viewWS, normalWS);
                roughness = roughness * (1.7 - 0.7 * roughness);
                float midLevel = roughness * 6;
                float specColor = SAMPLE_TEXTURECUBE_LOD(unity_SpecCube0, samplerunity_SpecCube0,
                    reflectDirectionWS, midLevel);
                #if !defined(UNITY_USE_NATIVE_HDR)
                return specColor * AO;
                #else
                return DecodeHDREnvironment(specColor, unity_SpecCube0_HDR);
                #endif
            }

            real3 IndirectSpecularFactor(float roughness, float NdotV)
            {
                //  float surfaceReduction = 1.0 / (roughness * roughness + 1.0);
                // #if defined(SHADER_API_GLES)
                // float reflectivity = specularBrdf.x;
                // #else
                // float reflectivity = max(max(specularBrdf.x, specularBrdf.y), specularBrdf.z);
                // #endif
                return tex2D(_BrdfLUT, float2(max(NdotV, 0.0), roughness));
            }

            v2f vert (appdata v)
            {
                v2f o = (v2f)0;
                o.positionCS = TransformObjectToHClip(v.positionOS.xyz);
                o.uv = TRANSFORM_TEX(v.uv, _BaseMap);

                VertexNormalInputs normalInput = GetVertexNormalInputs(v.normalOS, v.tangentOS);
                o.normalWS = normalInput.normalWS;
                real sign = v.tangentOS.w * GetOddNegativeScale();
                o.tangentWS = half4(normalInput.tangentWS.xyz, sign);
                return o;
            }

            half4 frag (v2f i) : SV_Target
            {
                half3 viewWS = normalize(_WorldSpaceCameraPos.xyz);
                half3 lightWS = normalize(_MainLightPosition.xyz);
                half3 halfWS = normalize(viewWS + lightWS);
                
                // 光栅化的时候插值运算可能会导致 vs 传过来的normalWS不是单位长度
                // half3 normalWS = normalize(i.normalWS);

                // 采样法线贴图
                float sgn = i.tangentWS.w;
                float3 bitangent = sgn * cross(i.normalWS.xyz, i.tangentWS.xyz);
                half3 normalTS = UnpackNormal(SAMPLE_TEXTURE2D(_BumpMap, sampler_BumpMap, i.uv));
                half3 normalWS = mul(normalTS, half3x3(i.tangentWS.xyz, bitangent.xyz, i.normalWS.xyz));
                normalWS = normalize(normalWS);
                
                half NdotH = max(dot(normalWS, halfWS), 0.00001);
                half NdotL = max(dot(normalWS, lightWS), 0.00001);
                half NdotV = max(dot(normalWS, viewWS), 0.00001);
                half HdotL = max(dot(halfWS, lightWS), 0.00001);
                half4 albedo = tex2D(_BaseMap, i.uv);
                
                float NDF = D_Function(NdotH, _Roughness);
                float G = G_Function(NdotL, NdotV, _Roughness);
                half3 F0 = half3(0.04, 0.04, 0.04);
                F0 = lerp(F0, _BaseColor.rgb * albedo.xyz, _Metalness);
                float3 F = F_Function(HdotL, F0);

                // direct specular
                float3 ks = F;
                float3 nominator = NDF * G * F;
                float denominator = 4.0 * NdotV * NdotL;
                float3 specularBrdf = nominator / denominator;

                // direct diffuse
                float3 kD = float3(1.0, 1.0, 1.0) - ks;
                kD *= 1.0 - _Metalness;
                nominator = kD * albedo;
                // denominator = PI;
                float3 diffuceBrdf = nominator;

                Light mainLight = GetMainLight();
                float3 radiance = mainLight.color * mainLight.distanceAttenuation;

                // indirect diffuse
                float3 indirectIrradiance = SH_IndirectDiffuse(normalWS);
                float3 indirectKs = GetIndirectKs(NdotV, F0, _Roughness);
                float3 indirectKd = (1 - indirectKs) * (1.0 - _Metalness);
                // float3 indirectDiffuse = indirectIrradiance * albedo * indirectKd * AO;
                float3 indirectDiffuse = indirectIrradiance * albedo * indirectKd;

                // indirect specular
                float3 prefilteredColor = SampleIndirectCube(normalWS, viewWS, _Roughness, 1.0);
                float2 indirectSpecularBrdf = IndirectSpecularFactor(_Roughness, NdotV);
                float3 indirectSpecular = prefilteredColor * (indirectKs * indirectSpecularBrdf.x + indirectSpecularBrdf.y);
                
                // 精确光源的颜色要乘PI
                float3 Lo = (diffuceBrdf + specularBrdf * PI) * radiance * NdotL;
                Lo += indirectDiffuse + indirectSpecular;
                
                // return half4(Lo,1);
                return half4(Lo,1);
            }
            ENDHLSL
        }
    }
}
