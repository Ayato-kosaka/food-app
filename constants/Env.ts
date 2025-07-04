import Constants from "expo-constants";

const extra = Constants.expoConfig?.extra ?? {};

export const Env = {
	APP_VERSION: Constants.expoConfig?.version as string,
	COMMIT_ID: extra.EXPO_PUBLIC_COMMIT_ID as string,
	NODE_ENV: extra.EXPO_PUBLIC_NODE_ENV as string,
	APP_STORE_URL: extra.EXPO_PUBLIC_APP_STORE_URL as string,
	PLAY_STORE_URL: extra.EXPO_PUBLIC_PLAY_STORE_URL as string,
	GOOGLE_MAPS_API_KEY: extra.EXPO_PUBLIC_GOOGLE_MAPS_API_KEY as string,
	ADMOB_ANDROID_INTERSTITIAL_UNIT_ID: extra.EXPO_PUBLIC_ADMOB_ANDROID_INTERSTITIAL_UNIT_ID as string,
	ADMOB_IOS_INTERSTITIAL_UNIT_ID: extra.EXPO_PUBLIC_ADMOB_IOS_INTERSTITIAL_UNIT_ID as string,
	ADMOB_ANDROID_BANNER_UNIT_ID: extra.EXPO_PUBLIC_ADMOB_ANDROID_BANNER_UNIT_ID as string,
	ADMOB_IOS_BANNER_UNIT_ID: extra.EXPO_PUBLIC_ADMOB_IOS_BANNER_UNIT_ID as string,
};
