package com.hogan.removejobnotvpn;

import android.app.job.JobInfo;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;

import java.lang.reflect.Field;
import java.lang.reflect.Method;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage;

public class MainHook implements IXposedHookLoadPackage {

    private static final int NET_CAPABILITY_NOT_VPN = NetworkCapabilities.NET_CAPABILITY_NOT_VPN;

    @Override
    public void handleLoadPackage(final XC_LoadPackage.LoadPackageParam loadPackageParam) throws Throwable {
        XposedHelpers.findAndHookMethod(
                JobInfo.Builder.class,
                "setRequiredNetwork",
                NetworkRequest.class,
                new XC_MethodHook() {
                    @Override
                    protected void beforeHookedMethod(MethodHookParam param) throws Throwable {
                        NetworkRequest request = (NetworkRequest) param.args[0];
                        if (request == null) {
                            return;
                        }
                        if (request.hasCapability(NET_CAPABILITY_NOT_VPN)) {
                            NetworkRequest modifiedRequest = buildRequestWithoutNotVpn(request, loadPackageParam.packageName);
                            if (modifiedRequest != null) {
                                param.args[0] = modifiedRequest;
                            }
                        }
                    }
                }
        );
    }

    private NetworkRequest buildRequestWithoutNotVpn(NetworkRequest originalRequest, String packageName) {
        try {
            NetworkRequest rebuilt = new NetworkRequest.Builder(originalRequest)
                    .removeCapability(NET_CAPABILITY_NOT_VPN)
                    .build();
            if (!rebuilt.hasCapability(NET_CAPABILITY_NOT_VPN)) {
                XposedBridge.log("RemoveJobNotVpn: Rebuilt NetworkRequest without NOT_VPN in " + packageName);
                return rebuilt;
            }
        } catch (Throwable ignored) {
        }

        try {
            Field capabilitiesField = NetworkRequest.class.getDeclaredField("networkCapabilities");
            capabilitiesField.setAccessible(true);
            NetworkCapabilities capabilities = (NetworkCapabilities) capabilitiesField.get(originalRequest);
            if (capabilities != null) {
                Method removeCapabilityMethod = NetworkCapabilities.class.getDeclaredMethod("removeCapability", int.class);
                removeCapabilityMethod.setAccessible(true);
                removeCapabilityMethod.invoke(capabilities, NET_CAPABILITY_NOT_VPN);
                XposedBridge.log("RemoveJobNotVpn: Removed NOT_VPN via reflection in " + packageName);
            }
        } catch (Throwable throwable) {
            XposedBridge.log("RemoveJobNotVpn: Failed to remove NOT_VPN in " + packageName + ": " + throwable.getMessage());
        }
        return originalRequest;
    }
}
