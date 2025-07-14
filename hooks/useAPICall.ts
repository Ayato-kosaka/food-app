import { useCallback } from "react";
import { Env } from "@/constants/Env";
import { useLogger } from "./useLogger";
import { useAuth } from "@/contexts/AuthProvider";
import i18n from "@/lib/i18n";
import { useDialog } from "@/contexts/DialogProvider";
import { Linking, Platform } from "react-native";

type APIVersion = "v1" | "v2";

/**
 * ☁️ API 呼び出しフック
 *
 * - 認証セッションの JWT を Authorization ヘッダーに付与
 * - multipart/form-data または JSON 形式の POST に対応
 * - 呼び出しと同時にログを出力し、レスポンスを返す
 * - 通信エラー時はログ記録した上で例外をスロー
 *
 * @returns { callBackend } - API 呼び出し関数
 * @throws ネットワークエラー、認証なし・応答エラー時
 */
export const useAPICall = () => {
    const { logFrontendEvent } = useLogger();
    const { showDialog } = useDialog();
    const { session } = useAuth();

    /**
     * 指定されたエンドポイントに対して API を呼び出す関数
     *
     * @param endpointName - エンドポイント名（例: "listDishMedia"）
     * @param requestPayload - リクエストボディ（JSONまたはFormData）
     * @param version - バージョン名（"v1" or "v2"）
     * @param isMultipart - multipart/form-data を使用するか
     * @returns {Promise<R>} - レスポンスデータ
     * @throws ネットワークエラーまたは認証なし・応答エラー時に例外をスロー
     */
    const callBackend = useCallback(
        async <T extends Record<string, any> | FormData, R>(
            endpointName: string,
            version: APIVersion,
            { method = 'POST', requestPayload, isMultipart = false }: {
                method?: 'GET' | 'POST';
                requestPayload: T; isMultipart?: boolean;
            }
        ): Promise<R> => {
            const appVersion = Env.APP_VERSION;
            const qs =
                method === 'GET' && !(requestPayload instanceof FormData)
                    ? `?${new URLSearchParams(requestPayload).toString()}`
                    : '';
            const endpoint = `${Env.BACKEND_BASE_URL}/${version}/${endpointName}${qs}`;

            // 🔐 認証トークンの有無をチェック
            const accessToken = session?.access_token;
            if (!accessToken) {
                throw new Error("User is not authenticated: Supabase access_token is missing.");
            }

            // 🧾 リクエストヘッダー構築
            const headers: Record<string, string> = {
                "x-app-version": appVersion,
                Authorization: `Bearer ${accessToken}`,
            };
            if (!isMultipart) {
                headers["Content-Type"] = "application/json";
            }

            // 🌐 API 呼び出し
            const response = await fetch(endpoint, {
                method,
                headers,
                body: method === 'POST' ? (isMultipart ? (requestPayload as FormData) : JSON.stringify(requestPayload)) : undefined,
            });

            const requestId = response.headers.get("x-request-id");

            // ❌ エラー処理
            if (!response.ok) {
                const errorMessage = `API call to ${endpointName} failed with status ${response.status} (requestId: ${requestId})`;

                let errorPayload: { error?: string; message?: string } = {};
                try {
                    errorPayload = await response.json();
                } catch {
                    // レスポンスボディがJSONでない場合はスキップ
                }

                // 特定エラーコードによる分岐
                if (response.status === 403) {
                    switch (errorPayload.error) {
                        case "Service maintenance":
                            showDialog(i18n.t("Error.maintenanceMessage")); // 🧃 表示のみ（アプリ全体は操作制限済み想定）
                            throw {
                                code: "maintenance_mode",
                                message: errorPayload.message || errorMessage,
                                requestId,
                            };
                        case "Unsupported version":
                            const storeUrl = Platform.select({
                                ios: Env.APP_STORE_URL, // iOS の App Store URL
                                android: Env.PLAY_STORE_URL, // Android の Play Store URL
                            });
                            showDialog(i18n.t("Error.unsupportedVersion"), {
                                // 🧃 表示のみ（アプリ全体は操作制限済み想定）
                                okLabel: i18n.t("Common.goStore"),
                                onConfirm: () => storeUrl && Linking.openURL(storeUrl),
                            });
                            throw {
                                code: "unsupported_version",
                                message: errorPayload.message || errorMessage,
                                requestId,
                            };
                        default:
                            throw {
                                code: "forbidden",
                                message: errorPayload.message || errorMessage,
                                requestId,
                            };
                    }
                }

                // その他の HTTP エラー
                throw {
                    code: "http_error",
                    status: response.status,
                    message: `API call to ${endpointName} failed with status ${response.status}`,
                    requestId,
                };
            }

            logFrontendEvent({
                event_name: `api_call_${endpointName}`,
                error_level: "info",
                payload: {
                    requestPayload: isMultipart ? "[multipart/form-data]" : requestPayload,
                    endpoint,
                    method,
                    version,
                    requestId,
                },
            });

            return await response.json();
        },
        [logFrontendEvent, session, showDialog],
    );

    return { callBackend };
};