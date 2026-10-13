// Copyright 2025 Factor Enovations Pvt Ltd
// Licensed under the Apache License, Version 2.0

package tech.efactor.ui.activities;

import android.Manifest;
import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.content.res.ColorStateList;
import android.location.LocationManager;
import android.net.wifi.ScanResult;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.text.TextUtils;
import android.util.Log;
import android.view.View;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.appcompat.app.AlertDialog;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;
import androidx.core.widget.ContentLoadingProgressBar;
import androidx.fragment.app.DialogFragment;
import androidx.fragment.app.Fragment;
import androidx.recyclerview.widget.LinearLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

import com.google.android.material.appbar.MaterialToolbar;
import com.google.android.material.chip.Chip;
import com.google.android.material.chip.ChipGroup;
import com.google.android.material.snackbar.Snackbar;

import org.greenrobot.eventbus.EventBus;
import org.greenrobot.eventbus.Subscribe;
import org.greenrobot.eventbus.ThreadMode;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.TimeZone;

import tech.efactor.AppConstants;
import tech.efactor.cloudapi.ApiManager;
import tech.efactor.proto.DeviceConnectionEvent;
import tech.efactor.proto.EfactorCloudManager;
import tech.efactor.proto.EfactorConstants;
import tech.efactor.proto.EfactorDevice;
import tech.efactor.proto.EfactorDeviceOperationRequest;
import tech.efactor.proto.EfactorLibraryManager;
import tech.efactor.proto.EfactorProvisionManager;
import tech.efactor.proto.listeners.ApiLibResponseListener;
import tech.efactor.proto.listeners.ProvisionListener;
import tech.efactor.proto.listeners.ResponseListener;
import tech.efactor.proto.models.EfactorNode;
import tech.efactor.smartthings.R;
import tech.efactor.ui.adapters.WifiNetworkAdapter;
import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import tech.efactor.ui.fragments.WifiPasswordDialogFragment;
import tech.efactor.ui.models.UpdateEvent;

/**
 * Single-activity provisioning flow — Template C "Minimal phase" style.
 *
 * Phases (in order):
 *   SCAN      – Wi-Fi scan looking for the device's SoftAP SSID
 *   P2P       – Connecting peer-to-peer to the device
 *   WIFI_PICK – User picks home Wi-Fi (was WiFiConfigActivity)
 *   PROVISION – Runs all provisioning steps (was ProvisionActivity)
 *   SUCCESS   – Done
 *   ERROR     – Something went wrong; user can retry
 *   TIMEOUT   – Scan timed-out or weak signal
 *
 * Key benefits vs the old 3-activity flow:
 *   • EfactorDevice object stays alive for the entire session
 *   • Disconnect mid-provision → auto-resets to SCAN and retries
 *   • No Intent extras needed between phases; everything is in-memory
 *   • Single EventBus subscriber handles all device + update events
 */
public class ProvisionLanding extends AppCompatActivity {

    private static final String TAG = "ProvisionLanding";

    // ─── Permission / Activity result codes ──────────────────────────────────
    private static final int REQUEST_FINE_LOCATION    = 10;
    private static final int WIFI_SETTINGS_REQUEST    = 11;
    private static final int REQUEST_LOCATION_ENABLE  = 12;

    // ─── Timing constants ────────────────────────────────────────────────────
    private static final long STAGE_TIMEOUT_MS        = 60_500L;
    private static final long MIN_SCAN_INTERVAL_MS    = 5_000L;
    private static final long MAX_BACKOFF_MS           = 15_000L;
    private static final long CONNECT_TIMEOUT_MS      = 10_000L;
    private static final int  MIN_RSSI_FOR_PROV       = -75;       // dBm
    private static final long ADD_DEVICE_REQ_TIME     = 15_000L;
    private static final long NODE_STATUS_REQ_TIME    = 45_000L;

    // ─── Phase enum ──────────────────────────────────────────────────────────
    // New flow: WIFI_PICK (pill1) → SCAN (pill2) → P2P (pill3) → PROVISION (pill4)
    // User selects home network first so credentials are ready before P2P starts.
    private enum Phase { WIFI_PICK, SCAN, P2P, PROVISION, SUCCESS, ERROR, TIMEOUT }
    private Phase currentPhase = Phase.WIFI_PICK;

    // ─── Managers ────────────────────────────────────────────────────────────
    private EfactorProvisionManager provisionManager;
    private ApiManager              apiManager;
    private EfactorCloudManager     cloudManager;
    private WifiManager             wifiManager;

    // ─── Intent extras ───────────────────────────────────────────────────────
    private String deviceName;          // human-readable device label
    private String expectedSoftApSsid;  // e.g. "EWIFI_A3F2"
    private String pop;                 // proof of possession / node id
    private String connectivityType;

    // ─── Scan state ──────────────────────────────────────────────────────────
    private BroadcastReceiver wifiScanReceiver;
    private boolean scanInFlight        = false;
    private boolean scanListReady       = false;
    private boolean btnConnectPressed   = false;
    private boolean connectRequested    = false;
    private boolean ignoreScanBroadcasts = false;
    private boolean connectingStarted   = false;
    private boolean p2pRetryAttempted   = false; // one P2P retry only
    private boolean weakSignalFound     = false;
    private int     expectedRssi        = Integer.MIN_VALUE;
    private long    lastScanAtMs        = 0L;
    private long    backoffMs           = 2_000L;
    private boolean nextScanScheduled   = false;
    private final ArrayList<String> scanSsids = new ArrayList<>();

    private final Handler scanHandler    = new Handler(Looper.getMainLooper());
    private final Handler stageHandler   = new Handler(Looper.getMainLooper());
    private final Handler connectHandler = new Handler(Looper.getMainLooper());
    private Runnable connectTimeoutRunnable;

    // ─── WiFi pick state ─────────────────────────────────────────────────────
    private WifiNetworkAdapter adapter24, adapter5;
    private TextView tvEmpty24;
    private ContentLoadingProgressBar progressRescan;
    private String selectedSsid;
    private String selectedPassword;
    private int    pendingNetworkRssi = 0; // RSSI of picked network — for signal warning

    // ─── Provision state ─────────────────────────────────────────────────────
    private boolean isProvisioningCompleted = false;
    private String  receivedNodeId;
    private String  secretKey;
    private int     addDeviceReqCount    = 0;
    private boolean addDeviceGaveUp      = false; // guard: blocks ghost callbacks after 10 retries
    private boolean nodeStatusPollingDone = false; // guard: blocks ghost callbacks after 45s watchdog
    private final Handler provHandler = new Handler(Looper.getMainLooper());

    private boolean error_flag1, error_flag2, error_flag3, error_flag4, error_flag5;
    private boolean error_flag6, error_flag7, error_flag8, error_flag9, error_flag10;
    private boolean progress_flag5;
    // Direct AlertDialog reference — inflate custom_dialog.xml, no fragment needed
    private AlertDialog activeErrorDialog;

    // ─── Phase container views ───────────────────────────────────────────────
    private View containerScan;
    private View containerWifiPick;
    private View containerProvision;
    private androidx.core.widget.NestedScrollView nestedScrollView;

    // ─── Pill indicators (Template C) ────────────────────────────────────────
    private View pill1, pill2, pill3, pill4;

    // ─── SCAN / P2P phase views ───────────────────────────────────────────────
    private ImageView  ivPhaseIcon;
    private TextView   tvPhaseTitle;
    private TextView   tvPhaseSubtitle;
    private TextView   tvDeviceName;
    private ContentLoadingProgressBar progressBar;
    private View       btnConnect;
    private TextView   txtConnectBtn;
    private View       btnConnectArrow;
    private View       btnConnectSpinner;

    // ─── WIFI PICK phase views ────────────────────────────────────────────────
    private RecyclerView rv24, rv5;

    // ─── PROVISION phase views ────────────────────────────────────────────────
    private ImageView tick1, tick2, tick3, tick4, tick5, tick6, tick7, tick8, tick9;
    private ContentLoadingProgressBar
            progress1, progress2, progress3, progress4, progress5,
            progress6, progress7, progress8, progress9;
    private TextView tvErrAtStep1, tvErrAtStep2, tvErrAtStep5,
            tvErrAtStep6, tvErrAtStep7, tvErrAtStep8, tvErrAtStep9;
    private TextView    tvProvSuccess, tvProvError, tvSuccessSsid;
    private View        layoutSuccessState;

    // ─── Focus view (Option 4) ───────────────────────────────────────────────
    private android.widget.ProgressBar arcProgress;
    private TextView    tvStepNumber, tvStepTitle, tvStepSubtitle;
    private ChipGroup   chipGroupCompleted;
    private View[]      stepDots = new View[9];
    private int         currentStepIndex = 0;

    private static final String[] STEP_TITLES = {
            "Initializing session",
            "Registering device",
            "Sending Wi-Fi credentials",
            "Applying credentials",
            "Confirming Wi-Fi",
            "Confirming connection",
            "Configuring cloud",
            "Confirming association",
            "Setting up device"
    };
    private static final String[] STEP_SUBTITLES = {
            "Connecting to your device…",
            "Linking device to your account…",
            "Sending network details…",
            "Device applying Wi-Fi settings…",
            "Checking Wi-Fi connection…",
            "Verifying network status…",
            "Registering with cloud…",
            "Confirming device pairing…",
            "Almost done…"
    };
    private View        btnOk;
    private TextView    txtOkBtn;
    private LinearLayout layoutBtn;

    // =========================================================================
    // Lifecycle
    // =========================================================================

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_provision_landing_c);   // new merged layout

        // Read intent extras
        expectedSoftApSsid = getIntent().getStringExtra(AppConstants.KEY_DEVICE_NAME);
        deviceName         = expectedSoftApSsid;
        pop                = getIntent().getStringExtra(AppConstants.KEY_PROOF_OF_POSSESSION);
        connectivityType   = getIntent().getStringExtra("connectivity_type");
        selectedSsid       = getIntent().getStringExtra("router_ssid");
        selectedPassword   = getIntent().getStringExtra("router_password");

        if (TextUtils.isEmpty(expectedSoftApSsid) || TextUtils.isEmpty(pop)) {
            Intent error = new Intent();
            error.putExtra("status", "missing_device_credentials");
            error.putExtra("message", "Device SoftAP SSID and proof of possession are required.");
            setResult(RESULT_CANCELED, error);
            finish();
            return;
        }

        Log.d(TAG, "Expected SoftAP: " + expectedSoftApSsid + "  POP supplied=" + !TextUtils.isEmpty(pop));

        // Managers
        wifiManager     = (WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE);
        provisionManager = EfactorProvisionManager.getInstance(getApplicationContext());
        apiManager      = ApiManager.getInstance(getApplicationContext());
        cloudManager    = EfactorCloudManager.getInstance(getApplicationContext());

        // Create the device session once for the entire flow
        provisionManager.createEfactorDevice(
                EfactorConstants.TransportType.TRANSPORT_SOFTAP,
                EfactorConstants.SecurityType.SECURITY_1,
                pop);
        provisionManager.getEfactorDevice().setProofOfPossession(pop);
        provisionManager.getEfactorDevice().setDeviceId(pop);

        if (!wifiManager.isWifiEnabled() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            askToEnableWifi();
        }

        EventBus.getDefault().register(this);
        initViews();

        // Start Wi-Fi scan in background immediately so list is populated
        // by the time the user taps Next on the Wi-Fi pick screen.
        registerWifiScanReceiver();
        if (hasLocationPermission()) startWifiScanSafe();

        // When Flutter's native Wi-Fi picker already collected router credentials,
        // continue directly with device SoftAP discovery. Otherwise retain the
        // original all-in-one native flow.
        if (!TextUtils.isEmpty(selectedSsid)) {
            transitionTo(Phase.SCAN);
        } else {
            transitionTo(Phase.WIFI_PICK);
        }
    }

    @Override
    protected void onStart() {
        super.onStart();
        // Only register for phases that actually use the scan receiver
        if (currentPhase == Phase.WIFI_PICK || currentPhase == Phase.SCAN) {
            registerWifiScanReceiver();
        }
    }

    @Override
    protected void onStop() {
        super.onStop();
        unregisterWifiReceiverSafely();
    }

    @Override
    protected void onResume() {
        super.onResume();
        ignoreScanBroadcasts = false;
        if (currentPhase == Phase.SCAN) {
            registerWifiScanReceiver();
            stageHandler.removeCallbacks(stageTicker);
            stageHandler.postDelayed(stageTicker, STAGE_TIMEOUT_MS);
            if (wifiManager.isWifiEnabled()) startWifiScanSafe();
        } else if (currentPhase == Phase.WIFI_PICK) {
            registerWifiScanReceiver();
            List<ScanResult> cached = wifiManager.getScanResults();
            if (cached != null && !cached.isEmpty()) handleWifiResults(cached);
            if (wifiManager.isWifiEnabled()) startWifiScanSafe();
        }
        // P2P, PROVISION, SUCCESS, TIMEOUT, ERROR: receiver stays unregistered
    }

    @Override
    protected void onPause() {
        super.onPause();
        ignoreScanBroadcasts = true;
        cancelScheduledScan();
        stageHandler.removeCallbacks(stageTicker);
    }

    @Override
    protected void onDestroy() {
        stopConnectTimeout();
        stopRadarPulse();
        stopDotPulse();
        cancelScheduledScan();
        unregisterWifiReceiverSafely();
        stageHandler.removeCallbacks(stageTicker);
        provHandler.removeCallbacks(addDeviceTask);
        provHandler.removeCallbacks(getNodeStatusTask);
        provHandler.removeCallbacks(nodeStatusReqFailed);
        cloudManager.setProvisionStarted(false);
        try { EventBus.getDefault().unregister(this); } catch (Exception ignored) {}
        super.onDestroy();
    }

    @Override
    public void onBackPressed() {
        cancelScheduledScan();
        ignoreScanBroadcasts = true;
        unregisterWifiReceiverSafely();
        stageHandler.removeCallbacks(stageTicker);
        if (provisionManager.getEfactorDevice() != null) {
            provisionManager.getEfactorDevice().stopPingLocal();
            provisionManager.getEfactorDevice().disconnectDevice();
        }
        cloudManager.setProvisionStarted(false);
        try { EventBus.getDefault().unregister(this); } catch (Exception ignored) {}
        super.onBackPressed();
    }

    // =========================================================================
    // Phase machine — the single source of truth for what the user sees
    // =========================================================================

    private void transitionTo(Phase next) {
        currentPhase = next;
        Log.d(TAG, "→ Phase: " + next);

        // Bug 1 fix: update toolbar title per phase so it never shows stale text
        if (getSupportActionBar() != null) {
            switch (next) {
                case WIFI_PICK:
                    getSupportActionBar().setTitle(R.string.select_wifi_title);
                    break;
                case SCAN:
                case TIMEOUT:
                    getSupportActionBar().setTitle(R.string.title_activity_connect_device);
                    break;
                case P2P:
                    getSupportActionBar().setTitle(R.string.connecting_title);
                    break;
                case PROVISION:
                case SUCCESS:
                    getSupportActionBar().setTitle(R.string.title_activity_provisioning);
                    break;
                case ERROR:
                    getSupportActionBar().setTitle(R.string.title_activity_connect_device);
                    break;
            }
        }

        // Pills: skip for TIMEOUT/ERROR so pills freeze at failure state
        if (next != Phase.TIMEOUT && next != Phase.ERROR) {
            updatePills(next);
        }

        // Container visibility
        boolean showScan     = (next == Phase.SCAN || next == Phase.P2P
                || next == Phase.TIMEOUT || next == Phase.ERROR);
        boolean showWifiPick = (next == Phase.WIFI_PICK);
        boolean showProv     = (next == Phase.PROVISION || next == Phase.SUCCESS);

        containerScan.setVisibility(showScan     ? View.VISIBLE : View.GONE);
        containerWifiPick.setVisibility(showWifiPick ? View.VISIBLE : View.GONE);
        containerProvision.setVisibility(showProv ? View.VISIBLE : View.GONE);

        switch (next) {
            case WIFI_PICK:  applyUiWifiPick();  break;
            case SCAN:       applyUiScan();       break;
            case P2P:        applyUiP2P();        break;
            case PROVISION:  applyUiProvision();  break;
            case SUCCESS:    applyUiSuccess();    break;
            case TIMEOUT:    applyUiTimeout();    break;
            case ERROR:      break;
        }
    }

    // ── Pill indicator helper ────────────────────────────────────────────────

    private void updatePills(Phase phase) {
        int[] colors = pillColorsForPhase(phase);
        View[] pills = { pill1, pill2, pill3, pill4 };
        float radius = 4 * getResources().getDisplayMetrics().density;
        for (int i = 0; i < pills.length; i++) {
            if (pills[i] == null) continue;
            android.graphics.drawable.GradientDrawable d = new android.graphics.drawable.GradientDrawable();
            d.setShape(android.graphics.drawable.GradientDrawable.RECTANGLE);
            d.setCornerRadius(radius);
            d.setColor(colors[i]);
            pills[i].setBackground(d);
        }
    }

    /** Pill 1=Wi-Fi pick, Pill 2=Scan/Connect, Pill 3=P2P, Pill 4=Provision/Done */
    private int[] pillColorsForPhase(Phase phase) {
        int teal = ContextCompat.getColor(this, R.color.colorPrimary);
        int idle = ContextCompat.getColor(this, R.color.color_grey_light);
        switch (phase) {
            case WIFI_PICK:
                return new int[]{ teal, idle, idle, idle };
            case SCAN:
                return new int[]{ teal, teal, idle, idle };
            case P2P:
                return new int[]{ teal, teal, teal, idle };
            case PROVISION:
                return new int[]{ teal, teal, teal, teal };
            case SUCCESS:
                return new int[]{ teal, teal, teal, teal };
            case TIMEOUT:
            case ERROR:
                return new int[]{ teal, teal, idle, idle };
            default:
                return new int[]{ idle, idle, idle, idle };
        }
    }

    // ── Radar ring views ─────────────────────────────────────────────────────
    private View radarOuter, radarMid, radarInner;
    private final Handler radarHandler = new Handler(Looper.getMainLooper());
    private boolean radarRunning = false;

    private void initRadarViews() {
        radarOuter = containerScan == null ? null : containerScan.findViewById(R.id.radar_ring_outer);
        radarMid   = containerScan == null ? null : containerScan.findViewById(R.id.radar_ring_mid);
        radarInner = containerScan == null ? null : containerScan.findViewById(R.id.radar_ring_inner);
    }

    /** Scanning/connecting in progress — hide arrow, show white spinner in button */
    private void setBtnScanning(String label) {
        if (txtConnectBtn    != null) txtConnectBtn.setText(label);
        if (btnConnectArrow  != null) btnConnectArrow.setVisibility(View.GONE);
        if (btnConnectSpinner != null) btnConnectSpinner.setVisibility(View.VISIBLE);
        if (btnConnect       != null) { btnConnect.setEnabled(false); btnConnect.setAlpha(0.85f); }
    }

    /** Ready for user action — show arrow, hide spinner */
    private void setBtnReady(String label) {
        if (txtConnectBtn    != null) txtConnectBtn.setText(label);
        if (btnConnectArrow  != null) btnConnectArrow.setVisibility(View.VISIBLE);
        if (btnConnectSpinner != null) btnConnectSpinner.setVisibility(View.GONE);
        if (btnConnect       != null) { btnConnect.setEnabled(true); btnConnect.setAlpha(1f); }
    }

    private void startRadarPulse() {
        if (radarRunning) return;
        radarRunning = true;
        if (radarOuter == null) initRadarViews();
        if (radarOuter == null) return;
        pulseRing(radarInner,  0);
        pulseRing(radarMid,   250);
        pulseRing(radarOuter, 500);
    }

    private void pulseRing(View ring, long delay) {
        if (ring == null) return;
        radarHandler.postDelayed(new Runnable() {
            @Override public void run() {
                if (!radarRunning || ring == null) return;
                // Fade in + scale up
                ring.setAlpha(0f);
                ring.setScaleX(0.85f);
                ring.setScaleY(0.85f);
                ring.animate()
                        .alpha(1f).scaleX(1f).scaleY(1f)
                        .setDuration(700)
                        .withEndAction(() -> {
                            if (!radarRunning) return;
                            // Fade out
                            ring.animate()
                                    .alpha(0f)
                                    .setDuration(700)
                                    .withEndAction(() -> {
                                        if (radarRunning) radarHandler.postDelayed(this, 200);
                                    })
                                    .start();
                        })
                        .start();
            }
        }, delay);
    }

    private void stopRadarPulse() {
        radarRunning = false;
        radarHandler.removeCallbacksAndMessages(null);
        // Cancel animations and reset scale — views may be mid-pulse
        if (radarOuter != null) { radarOuter.animate().cancel(); radarOuter.setScaleX(1f); radarOuter.setScaleY(1f); }
        if (radarMid   != null) { radarMid.animate().cancel();   radarMid.setScaleX(1f);   radarMid.setScaleY(1f);   }
        if (radarInner != null) { radarInner.animate().cancel(); radarInner.setScaleX(1f); radarInner.setScaleY(1f); }
    }

    /** Called on device found — rings go solid bright, no more pulsing */
    private void setRadarFoundState() {
        // Rings smoothly transition to full brightness and stay static
        if (radarInner != null) radarInner.animate().alpha(1.0f).scaleX(1f).scaleY(1f).setDuration(300).start();
        if (radarMid   != null) radarMid.animate().alpha(0.85f).scaleX(1f).scaleY(1f).setDuration(300).start();
        if (radarOuter != null) radarOuter.animate().alpha(0.65f).scaleX(1f).scaleY(1f).setDuration(300).start();
    }

    // ── Per-phase UI appliers ─────────────────────────────────────────────────

    private void applyUiScan() {
        initRadarViews();
        // Start rings invisible — pulse animation fades them in
        if (radarOuter != null) { radarOuter.setAlpha(0f); radarOuter.setScaleX(1f); radarOuter.setScaleY(1f); }
        if (radarMid   != null) { radarMid.setAlpha(0f);   radarMid.setScaleX(1f);   radarMid.setScaleY(1f);   }
        if (radarInner != null) { radarInner.setAlpha(0f); radarInner.setScaleX(1f); radarInner.setScaleY(1f); }
        ivPhaseIcon.setImageResource(R.drawable.ic_wifi_scan);
        tvPhaseTitle.setText(R.string.scanning_title);
        tvPhaseSubtitle.setText("Keep the device nearby.");

        if (!TextUtils.isEmpty(deviceName)) {
            tvDeviceName.setVisibility(View.VISIBLE);
            tvDeviceName.setText(deviceName);
        } else {
            tvDeviceName.setVisibility(View.GONE);
        }

        // Auto-start: show spinner in button, hide arrow, begin scanning immediately
        setBtnScanning("Searching…");
        startRadarPulse();
        btnConnectPressed = true;
        scanListReady     = false;
        scanSsids.clear();

        // Arm 60s timeout
        stageHandler.removeCallbacks(stageTicker);
        stageHandler.postDelayed(stageTicker, STAGE_TIMEOUT_MS);

        if (wifiManager.isWifiEnabled()) {
            maybeStartWifiScan();
        } else {
            showWifiNotEnabledDialog();
        }
    }

    private void applyUiP2P() {
        cancelScheduledScan();
        unregisterWifiReceiverSafely();
        initRadarViews();
        stopRadarPulse();
        setRadarFoundState();
        ivPhaseIcon.setImageResource(R.drawable.ic_link_device);
        tvPhaseTitle.setText(R.string.connecting_title);
        tvPhaseSubtitle.setText(R.string.connecting_subtitle);
        setBtnScanning("Connecting…");

    }

    private void applyUiWifiPick() {
        // Reset cached lists so first scan always shows
        lastSsids24.clear();
        lastSsids5.clear();
        // Populate from cached results immediately
        List<ScanResult> fresh = wifiManager.getScanResults();
        if (fresh != null && !fresh.isEmpty()) {
            handleWifiResults(fresh);
        }
        // Trigger one background rescan then stop
        if (progressRescan != null) progressRescan.setVisibility(View.VISIBLE);
        ignoreScanBroadcasts = false;
        registerWifiScanReceiver();
        startWifiScanSafe();
    }

    private void applyUiProvision() {
        cancelScheduledScan();
        unregisterWifiReceiverSafely();
        resetProvisionStepViews();
        cloudManager.setProvisionStarted(true);
        if (nestedScrollView != null) {
            nestedScrollView.post(() -> nestedScrollView.smoothScrollTo(0, 0));
        }
        // Mirror ProvisionActivity.onCreate() exactly — call doStep1/associateDevice immediately.
        // The SDK handles session internally inside sendDataToCustomEndPoint.
        // Do NOT wait for EVENT_DEVICE_SESSION_ESTABLISHED — that only advances UI to doStep2.
        provHandler.post(this::startProvisionSteps);
        // provHandler.postDelayed(this::startProvisionSteps, 3000);

    }

    private void applyUiSuccess() {
        cancelScheduledScan();
        unregisterWifiReceiverSafely();
        stopDotPulse();
        // Hide in-progress elements — success shows its own full ring
        View arcFrame = containerProvision == null ? null : containerProvision.findViewById(R.id.arc_frame);
        if (arcFrame != null) arcFrame.setVisibility(View.GONE);
        View dotRow = containerProvision == null ? null : containerProvision.findViewById(R.id.dot_row);
        if (dotRow != null) dotRow.setVisibility(View.GONE);
        View chipGroup = containerProvision == null ? null : containerProvision.findViewById(R.id.chip_group_completed);
        if (chipGroup != null) chipGroup.setVisibility(View.GONE);
        View stepTitle = containerProvision == null ? null : containerProvision.findViewById(R.id.tv_step_title);
        if (stepTitle != null) stepTitle.setVisibility(View.GONE);
        View stepSub = containerProvision == null ? null : containerProvision.findViewById(R.id.tv_step_subtitle);
        if (stepSub != null) stepSub.setVisibility(View.GONE);

        if (layoutSuccessState != null) layoutSuccessState.setVisibility(View.VISIBLE);
        if (tvProvSuccess != null)      tvProvSuccess.setVisibility(View.VISIBLE);
        if (tvSuccessSsid != null && !TextUtils.isEmpty(selectedSsid)) {
            tvSuccessSsid.setText("Connected to " + selectedSsid);
        }
        btnOk.setEnabled(true);
        btnOk.setAlpha(1f);
        txtOkBtn.setText(R.string.btn_done);
        cloudManager.setProvisionStarted(false);
    }

    private void applyUiTimeout() {
        stageHandler.removeCallbacks(stageTicker);
        cancelScheduledScan();
        unregisterWifiReceiverSafely();
        stopConnectTimeout();
        stopRadarPulse();
        // Dim radar rings on timeout
        if (radarOuter != null) radarOuter.setAlpha(0.1f);
        if (radarMid   != null) radarMid.setAlpha(0.15f);
        if (radarInner != null) radarInner.setAlpha(0.25f);
        if (weakSignalFound) {
            weakSignalFound = false;
            ivPhaseIcon.setImageResource(R.drawable.ic_weak_signal);
            tvPhaseTitle.setText(R.string.weak_wifi_title);
            tvPhaseSubtitle.setText(getString(R.string.weak_wifi_message, expectedRssi));
        } else {
            ivPhaseIcon.setImageResource(R.drawable.ic_timeout);
            tvPhaseTitle.setText(R.string.timeout_title);
            tvPhaseSubtitle.setText(R.string.timeout_subtitle);
        }
        setBtnReady(getString(R.string.btn_try_again));

    }

    // =========================================================================
    // View initialisation
    // =========================================================================

    private void initViews() {
        MaterialToolbar toolbar = findViewById(R.id.toolbar);
        setSupportActionBar(toolbar);
        if (getSupportActionBar() != null) {
            getSupportActionBar().setDisplayHomeAsUpEnabled(true);
            getSupportActionBar().setTitle(R.string.title_activity_connect_device);
        }
        toolbar.setNavigationIcon(R.drawable.ic_arrow_left);
        toolbar.setNavigationOnClickListener(v -> onBackPressed());

        // Pills
        pill1 = findViewById(R.id.pill_1);
        pill2 = findViewById(R.id.pill_2);
        pill3 = findViewById(R.id.pill_3);
        pill4 = findViewById(R.id.pill_4);

        // Phase containers
        containerScan      = findViewById(R.id.container_scan);
        containerWifiPick  = findViewById(R.id.container_wifi_pick);
        containerProvision = findViewById(R.id.container_provision);
        nestedScrollView   = findViewById(R.id.nested_scroll);

        // ── SCAN container ────────────────────────────────────────────────────
        ivPhaseIcon   = containerScan.findViewById(R.id.iv_phase_icon);
        tvPhaseTitle  = containerScan.findViewById(R.id.tv_phase_title);
        tvPhaseSubtitle = containerScan.findViewById(R.id.tv_phase_subtitle);
        tvDeviceName  = containerScan.findViewById(R.id.tv_device_name);
        progressBar   = null; // replaced by button spinner — see btnConnectSpinner
        btnConnect       = findViewById(R.id.btn_connect);
        txtConnectBtn    = btnConnect.findViewById(R.id.text_btn);
        btnConnectArrow  = btnConnect.findViewById(R.id.iv_arrow);
        btnConnectSpinner = btnConnect.findViewById(R.id.progress_indicator);
        if (btnConnectArrow   != null) btnConnectArrow.setVisibility(View.VISIBLE);
        if (btnConnectSpinner != null) btnConnectSpinner.setVisibility(View.GONE);
        // Only used for timeout retry — scanning starts automatically on SCAN phase
        btnConnect.setOnClickListener(v -> onConnectClicked());

        // ── WIFI PICK container ────────────────────────────────────────────────
        rv24 = findViewById(R.id.rv24);
        rv5  = findViewById(R.id.rv5);
        tvEmpty24      = findViewById(R.id.tv_empty_24);
        progressRescan = findViewById(R.id.progress_rescan);
        adapter24 = new WifiNetworkAdapter(this::onWifiNetworkPicked);
        adapter5  = new WifiNetworkAdapter(r ->
                Snackbar.make(findViewById(android.R.id.content),
                        "5 GHz not supported. Select a 2.4 GHz network.",
                        Snackbar.LENGTH_SHORT).show());
        rv24.setLayoutManager(new LinearLayoutManager(this));
        rv5.setLayoutManager(new LinearLayoutManager(this));
        rv24.setAdapter(adapter24);
        rv5.setAdapter(adapter5);
        // Rescan: show spinner, re-register receiver, fire fresh scan
        findViewById(R.id.btn_rescan).setOnClickListener(v -> {
            progressRescan.setVisibility(View.VISIBLE);
            tvEmpty24.setVisibility(View.GONE);
            registerWifiScanReceiver();
            ignoreScanBroadcasts = false;
            startWifiScanSafe();
        });

        // ── PROVISION container ────────────────────────────────────────────────
        tick1 = findViewById(R.id.iv_tick_1);  tick2 = findViewById(R.id.iv_tick_2);
        tick3 = findViewById(R.id.iv_tick_3);  tick4 = findViewById(R.id.iv_tick_4);
        tick5 = findViewById(R.id.iv_tick_5);  tick6 = findViewById(R.id.iv_tick_6);
        tick7 = findViewById(R.id.iv_tick_7);  tick8 = findViewById(R.id.iv_tick_8);
        tick9 = findViewById(R.id.iv_tick_9);

        progress1 = findViewById(R.id.prov_progress_1); progress2 = findViewById(R.id.prov_progress_2);
        progress3 = findViewById(R.id.prov_progress_3); progress4 = findViewById(R.id.prov_progress_4);
        progress5 = findViewById(R.id.prov_progress_5); progress6 = findViewById(R.id.prov_progress_6);
        progress7 = findViewById(R.id.prov_progress_7); progress8 = findViewById(R.id.prov_progress_8);
        progress9 = findViewById(R.id.prov_progress_9);

        tvErrAtStep1 = findViewById(R.id.tv_prov_error_1);
        tvErrAtStep2 = findViewById(R.id.tv_prov_error_2);
        tvErrAtStep5 = findViewById(R.id.tv_prov_error_5);
        tvErrAtStep6 = findViewById(R.id.tv_prov_error_6);
        tvErrAtStep7 = findViewById(R.id.tv_prov_error_7);
        tvErrAtStep8 = findViewById(R.id.tv_prov_error_8);
        tvErrAtStep9 = findViewById(R.id.tv_prov_error_9);

        tvProvSuccess     = findViewById(R.id.tv_prov_success);
        tvProvError       = findViewById(R.id.tv_prov_error);
        tvSuccessSsid     = findViewById(R.id.tv_success_ssid);
        layoutSuccessState = findViewById(R.id.layout_success_state);

        // Focus view (Option 4) wiring
        arcProgress = (android.widget.ProgressBar) findViewById(R.id.arc_progress);
        if (arcProgress != null) {
            arcProgress.setMax(900);
            arcProgress.setProgress(0);
            // Clear any system tint that overrides our drawable color
            arcProgress.setProgressTintList(null);
            arcProgress.setProgressBackgroundTintList(null);
        }
        tvStepNumber      = findViewById(R.id.tv_step_number);
        tvStepTitle       = findViewById(R.id.tv_step_title);
        tvStepSubtitle    = findViewById(R.id.tv_step_subtitle);
        chipGroupCompleted= findViewById(R.id.chip_group_completed);
        stepDots[0] = findViewById(R.id.dot_1); stepDots[1] = findViewById(R.id.dot_2);
        stepDots[2] = findViewById(R.id.dot_3); stepDots[3] = findViewById(R.id.dot_4);
        stepDots[4] = findViewById(R.id.dot_5); stepDots[5] = findViewById(R.id.dot_6);
        stepDots[6] = findViewById(R.id.dot_7); stepDots[7] = findViewById(R.id.dot_8);
        stepDots[8] = findViewById(R.id.dot_9);
        btnOk             = findViewById(R.id.btn_ok);
        txtOkBtn      = btnOk.findViewById(R.id.text_btn);
        layoutBtn     = btnOk.findViewById(R.id.layout_btn);
        btnOk.setOnClickListener(v -> onOkClicked());
        btnOk.setEnabled(false);
        btnOk.setAlpha(0.5f);
        View okArrow = btnOk.findViewById(R.id.iv_arrow);
        if (okArrow != null) okArrow.setVisibility(View.GONE);
        txtOkBtn.setText(R.string.btn_done);
    }

    // =========================================================================
    // SCAN phase — button click, scan loop, results
    // =========================================================================

    private void onConnectClicked() {
        // This is only called on timeout/error retry — normal scanning
        // auto-starts in applyUiScan() when transitioning to SCAN phase.
        if (currentPhase != Phase.TIMEOUT && currentPhase != Phase.ERROR) return;

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && !isLocationEnabled()) {
            askForLocation();
            return;
        }
        resetScanState();
        // Re-enter SCAN — applyUiScan will auto-start scanning + radar
        transitionTo(Phase.SCAN);
    }

    private void resetScanState() {
        stopRadarPulse();
        setBtnReady(getString(R.string.btn_try_again)); // will be overwritten by applyUiScan
        btnConnectPressed   = false;
        scanListReady       = false;
        connectRequested    = false;
        connectingStarted   = false;
        p2pRetryAttempted   = false;
        weakSignalFound     = false;
        ignoreScanBroadcasts = false;
        expectedRssi        = Integer.MIN_VALUE;
        backoffMs           = 2_000L;
        scanSsids.clear();
        cancelScheduledScan();
        stageHandler.removeCallbacks(stageTicker);
        registerWifiScanReceiver();
    }

    private void maybeStartWifiScan() {
        if (!wifiManager.isWifiEnabled()) { showWifiNotEnabledDialog(); return; }
        if (!hasLocationPermission())     { requestLocationPermission(); return; }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && !isLocationEnabled()) {
            askForLocation(); return;
        }
        startWifiScanSafe();
    }

    private void startWifiScanSafe() {
        if (!wifiManager.isWifiEnabled()) { showWifiNotEnabledDialog(); return; }
        if (!hasLocationPermission())     return;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && !isLocationEnabled()) {
            askForLocation(); return;
        }
        long now   = android.os.SystemClock.elapsedRealtime();
        long since = now - lastScanAtMs;
        if (since < MIN_SCAN_INTERVAL_MS) {
            scheduleNextScan(MIN_SCAN_INTERVAL_MS - since);
            return;
        }
        scanInFlight  = true;
        scanListReady = false;
        lastScanAtMs  = now;
        boolean ok = wifiManager.startScan();
        Log.d(TAG, "startScan() → " + ok + " backoff=" + backoffMs + "ms");
        if (!ok) {
            scanInFlight = false;
            scheduleNextScan(backoffMs);
            backoffMs = Math.min(backoffMs * 2, MAX_BACKOFF_MS);
        } else {
            backoffMs = 2_000L;
        }
    }

    private void handleScanBroadcast(boolean updated) {
        scanInFlight = false;
        List<ScanResult> results = wifiManager.getScanResults();

        if (currentPhase == Phase.WIFI_PICK) {
            if (results != null) handleWifiResults(results);
            return;
        }
        // All non-SCAN phases: ignore broadcast — prevent ghost scan loops
        if (currentPhase != Phase.SCAN) {
            Log.d(TAG, "handleScanBroadcast: ignoring in phase=" + currentPhase);
            return;
        }

        boolean foundExpected = false;
        scanSsids.clear();

        if (results != null) {
            for (ScanResult r : results) {
                if (!TextUtils.isEmpty(r.SSID)) {
                    scanSsids.add(r.SSID);
                    if (!TextUtils.isEmpty(expectedSoftApSsid) &&
                            r.SSID.equalsIgnoreCase(expectedSoftApSsid)) {
                        foundExpected = true;
                        expectedRssi  = r.level;
                    }
                }
            }
        }
        Log.d(TAG, "scan updated=" + updated + " count=" + scanSsids.size()
                + " found=" + foundExpected + " ssids=" + scanSsids);

        // Weak signal
        if (foundExpected && expectedRssi < MIN_RSSI_FOR_PROV) {
            Log.w(TAG, "Weak signal: " + expectedRssi + " dBm");
            weakSignalFound = true;
            transitionTo(Phase.TIMEOUT);
            return;
        }

        // Found & button was pressed — show "found" state briefly then connect
        if (foundExpected && btnConnectPressed) {
            scanListReady = true;
            if (connectRequested) return;
            connectRequested = true;
            cancelScheduledScan();
            ignoreScanBroadcasts = true;
            unregisterWifiReceiverSafely();

            // Show "Device found!" state for 800ms before transitioning to P2P
            stopRadarPulse();
            setRadarFoundState();
            ivPhaseIcon.setImageResource(R.drawable.ic_device_found); // checkmark
            tvPhaseTitle.setText("Device found!");
            tvPhaseSubtitle.setText(expectedSoftApSsid);
            tvDeviceName.setVisibility(View.GONE);
            setBtnScanning("Connecting…");

            new Handler(Looper.getMainLooper()).postDelayed(() -> {
                transitionTo(Phase.P2P);
                connectToDevice();
            }, 800);
            return;
        }

        // Not found yet — schedule next scan
        scheduleNextScan(Math.max(MIN_SCAN_INTERVAL_MS, backoffMs));
    }

    // Scan scheduler helpers
    private final Runnable nextScanRunnable = () -> {
        nextScanScheduled = false;
        startWifiScanSafe();
    };
    private void scheduleNextScan(long delayMs) {
        if (nextScanScheduled) return;
        nextScanScheduled = true;
        scanHandler.postDelayed(nextScanRunnable, Math.max(0, delayMs));
    }
    private void cancelScheduledScan() {
        scanHandler.removeCallbacks(nextScanRunnable);
        nextScanScheduled = false;
    }

    // Stage timeout — fires if device not found within STAGE_TIMEOUT_MS.
    // Intentionally ignores connectingStarted so the spinner can never run forever.
    private final Runnable stageTicker = () -> {
        if (isFinishing() || isDestroyed()) return;
        Log.w(TAG, "Stage timeout — connectingStarted=" + connectingStarted);
        cancelScheduledScan();
        stopConnectTimeout();
        connectingStarted = false;
        connectRequested  = false;
        transitionTo(Phase.TIMEOUT);
    };

    // Connect timeout
    private void startConnectTimeout() {
        stopConnectTimeout();
        connectTimeoutRunnable = () -> {
            if (isFinishing() || isDestroyed()) return;
            Log.w(TAG, "Connect timeout — device did not respond in " + CONNECT_TIMEOUT_MS + "ms");
            connectingStarted = false;
            connectRequested  = false;
            runOnUiThread(() -> transitionTo(Phase.TIMEOUT));
        };
        connectHandler.postDelayed(connectTimeoutRunnable, CONNECT_TIMEOUT_MS);
    }
    private void stopConnectTimeout() {
        if (connectTimeoutRunnable != null) {
            connectHandler.removeCallbacks(connectTimeoutRunnable);
            connectTimeoutRunnable = null;
        }
    }

    // =========================================================================
    // P2P connection
    // =========================================================================

    private void connectToDevice() {
        if (connectingStarted) return;
        connectingStarted = true;
        startConnectTimeout();
        // Secondary watchdog — stageTicker was removed when device was found in SCAN
        stageHandler.removeCallbacks(stageTicker);
        stageHandler.postDelayed(stageTicker, CONNECT_TIMEOUT_MS + 2_000L);
        Log.d(TAG, "Connecting to device via SoftAP…");
        if (ActivityCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION)
                == PackageManager.PERMISSION_GRANTED) {
            provisionManager.getEfactorDevice().getcrds(apiManager.getapiKey());
        } else {
            Toast.makeText(this, "Location permission required to connect device",
                    Toast.LENGTH_LONG).show();
        }
    }

    // =========================================================================
    // WiFi pick phase
    // =========================================================================

    private void onWifiNetworkPicked(ScanResult r) {
        pendingNetworkRssi = r.level; // capture before entering password dialog
        boolean secured = r.capabilities != null
                && r.capabilities.matches(".*(WEP|WPA|SAE|EAP).*");
        WifiPasswordDialogFragment f = WifiPasswordDialogFragment.newInstance(r.SSID, secured);
        f.setCallback(new WifiPasswordDialogFragment.Callback() {
            @Override public void onReselectRequested() { /* stay on list */ }
            @Override public void onPasswordConfirmed(String ssid, String password, boolean save) {
                selectedSsid     = ssid;
                selectedPassword = password;
                try {
                    Fragment pwdFrag = getSupportFragmentManager().findFragmentByTag("pwd");
                    if (pwdFrag instanceof DialogFragment) {
                        ((DialogFragment) pwdFrag).dismissAllowingStateLoss();
                    }
                } catch (Exception ignored) {}
                new Handler(Looper.getMainLooper()).post(() ->
                        checkWifiSignalAndProceed(pendingNetworkRssi, ssid));
            }
        });
        f.show(getSupportFragmentManager(), "pwd");
    }

    // Signal warning thresholds (phone → router RSSI)
    // Strong > -60    : proceed silently
    // Medium -60..-75 : soft warning via custom_dialog.xml
    // Weak   < -75    : strong warning via custom_dialog.xml
    private static final int RSSI_STRONG = -60;
    private static final int RSSI_MEDIUM = -75;

    private void checkWifiSignalAndProceed(int rssi, String ssid) {
        if (rssi >= RSSI_STRONG) { transitionTo(Phase.SCAN); return; }
        if (isFinishing() || isDestroyed()) return;

        String title, codeAndShort, points;
        if (rssi >= RSSI_MEDIUM) {
            title        = "Moderate Wi-Fi signal";
            codeAndShort = "\"" + ssid + "\"  (" + rssi + " dBm)";
            points       = "Your phone has a moderate connection to this network.\n\n"
                    + "Your device may connect more slowly than usual. "
                    + "Moving closer to your router may help.";
        } else {
            title        = "Weak Wi-Fi signal";
            codeAndShort = "\"" + ssid + "\"  (" + rssi + " dBm)";
            points       = "Your phone has a weak connection to this network.\n\n"
                    + "Your device may have an even weaker connection depending on its placement, "
                    + "which can cause slow setup, frequent disconnects, or provisioning failure.\n\n"
                    + "Please move your device or router closer to each other before continuing.";
        }
        View dialogView = getLayoutInflater().inflate(R.layout.custom_dialog, null);
        TextView tvDTitle = dialogView.findViewById(R.id.tvTitle);
        TextView tvDCode  = dialogView.findViewById(R.id.tvCodeAndShort);
        TextView tvDPts   = dialogView.findViewById(R.id.tvPoints);
        TextView btnCont  = dialogView.findViewById(R.id.btnRetry);
        TextView btnChng  = dialogView.findViewById(R.id.btnTroubleshoot);
        tvDTitle.setText(title);
        tvDCode.setText(codeAndShort);
        tvDPts.setText(points);
        btnCont.setText("CONTINUE");
        btnChng.setText("CHANGE NETWORK");
        AlertDialog signalDialog = new AlertDialog.Builder(this)
                .setView(dialogView).setCancelable(false).create();
        if (signalDialog.getWindow() != null)
            signalDialog.getWindow().setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
        btnCont.setOnClickListener(v -> { signalDialog.dismiss(); transitionTo(Phase.SCAN); });
        btnChng.setOnClickListener(v -> {
            signalDialog.dismiss();
            selectedSsid = null; selectedPassword = null;
        });
        signalDialog.show();
    }

    // Track last submitted lists to prevent continuous re-render on repeat scan broadcasts
    private List<String> lastSsids24 = new ArrayList<>();
    private List<String> lastSsids5  = new ArrayList<>();

    private void handleWifiResults(List<ScanResult> scan) {
        // Hide rescan spinner whenever results arrive
        if (progressRescan != null) progressRescan.setVisibility(View.GONE);

        List<ScanResult> deduped = dedupBySsidStrongest(scan);
        List<ScanResult> band24 = new ArrayList<>();
        List<ScanResult> band5  = new ArrayList<>();
        for (ScanResult r : deduped) {
            if (shouldHideNetwork(r)) continue;
            if (is24GHz(r.frequency)) band24.add(r);
            else if (is5GHz(r.frequency)) band5.add(r);
        }
        Comparator<ScanResult> byLevel = (a, b) -> Integer.compare(b.level, a.level);
        Collections.sort(band24, byLevel);
        Collections.sort(band5,  byLevel);

        // Only submit if list actually changed — prevents continuous RecyclerView re-render
        List<String> new24 = ssidKeys(band24);
        List<String> new5  = ssidKeys(band5);
        if (!new24.equals(lastSsids24)) {
            lastSsids24 = new24;
            adapter24.submitNow(band24);
        }
        if (!new5.equals(lastSsids5)) {
            lastSsids5 = new5;
            adapter5.submitNow(band5);
        }

        if (tvEmpty24 != null) {
            tvEmpty24.setVisibility(band24.isEmpty() ? View.VISIBLE : View.GONE);
        }
    }

    private List<String> ssidKeys(List<ScanResult> list) {
        List<String> keys = new ArrayList<>();
        for (ScanResult r : list) keys.add(r.SSID + "|" + r.BSSID);
        return keys;
    }

    private boolean shouldHideNetwork(ScanResult r) {
        if (r == null || TextUtils.isEmpty(r.SSID)) return true;
        return r.SSID.trim().regionMatches(true, 0, "EWIFI_", 0, 6);
    }
    private List<ScanResult> dedupBySsidStrongest(List<ScanResult> in) {
        Map<String, ScanResult> map = new HashMap<>();
        for (ScanResult r : in) {
            if (shouldHideNetwork(r)) continue;
            ScanResult prev = map.get(r.SSID);
            if (prev == null || r.level > prev.level) map.put(r.SSID, r);
        }
        return new ArrayList<>(map.values());
    }
    private boolean is24GHz(int f) { return f >= 2400 && f < 2500; }
    private boolean is5GHz (int f) { return f >= 4900 && f < 5900; }

    // =========================================================================
    // Provision phase — all steps (ported from ProvisionActivity)
    // =========================================================================

    private void resetProvisionErrorFlags() {
        error_flag1 = error_flag2 = error_flag3 = error_flag4 = error_flag5 = false;
        error_flag6 = error_flag7 = error_flag8 = error_flag9 = error_flag10 = false;
        progress_flag5 = false;
        isProvisioningCompleted = false;
        addDeviceReqCount     = 0;
        addDeviceGaveUp       = false;
        nodeStatusPollingDone = false;
    }

    private void resetProvisionStepViews() {
        resetProvisionErrorFlags();
        tvProvSuccess.setVisibility(View.GONE);
        tvProvError.setVisibility(View.GONE);
        if (layoutSuccessState != null) layoutSuccessState.setVisibility(View.GONE);
        resetFocusView();
        btnOk.setEnabled(false);
        btnOk.setAlpha(0.5f);

        // Reset all tick/progress pairs to their initial "waiting" state
        ImageView[] ticks = { tick1, tick2, tick3, tick4, tick5, tick6, tick7, tick8, tick9 };
        ContentLoadingProgressBar[] progresses = {
                progress1, progress2, progress3, progress4, progress5,
                progress6, progress7, progress8, progress9 };
        for (ImageView t : ticks) {
            if (t == null) continue;
            t.setImageResource(R.drawable.ic_checkbox_unselected);
            t.setVisibility(View.VISIBLE);
        }
        for (ContentLoadingProgressBar p : progresses) {
            if (p != null) p.setVisibility(View.GONE);
        }
        if (progress1 != null) progress1.setVisibility(View.VISIBLE);
        if (tick1 != null)     tick1.setVisibility(View.GONE);

        TextView[] errViews = { tvErrAtStep1, tvErrAtStep2, tvErrAtStep5,
                tvErrAtStep6, tvErrAtStep7, tvErrAtStep8, tvErrAtStep9 };
        for (TextView e : errViews) { if (e != null) e.setVisibility(View.GONE); }
    }

    /**
     * Option 4 Focus View — called every time a step becomes active.
     * stepIndex is 0-based. ProgressBar max=900, step N = N*100.
     */
    private void updateFocusStep(int stepIndex) {
        if (stepIndex < 0 || stepIndex >= 9) return;
        currentStepIndex = stepIndex;
        runOnUiThread(() -> {
            // Animated arc progress
            if (arcProgress != null) {
                android.animation.ObjectAnimator anim = android.animation.ObjectAnimator
                        .ofInt(arcProgress, "progress",
                                arcProgress.getProgress(), (stepIndex + 1) * 100);
                anim.setDuration(400);
                anim.setInterpolator(new android.view.animation.DecelerateInterpolator());
                anim.start();
            }
            if (tvStepNumber != null) tvStepNumber.setText(String.valueOf(stepIndex + 1));
            if (tvStepTitle != null)    tvStepTitle.setText(STEP_TITLES[stepIndex]);
            if (tvStepSubtitle != null) tvStepSubtitle.setText(STEP_SUBTITLES[stepIndex]);

            // Dots — done=teal, active=teal+pulse, idle=grey
            int dp8  = (int)(8  * getResources().getDisplayMetrics().density);
            int dp12 = (int)(12 * getResources().getDisplayMetrics().density);
            for (int i = 0; i < stepDots.length; i++) {
                if (stepDots[i] == null) continue;
                android.view.ViewGroup.LayoutParams lp = stepDots[i].getLayoutParams();
                if (i < stepIndex) {
                    stepDots[i].setBackgroundResource(R.drawable.bg_dot_done);
                    lp.width = lp.height = dp8;
                } else if (i == stepIndex) {
                    stepDots[i].setBackgroundResource(R.drawable.bg_dot_active);
                    lp.width = lp.height = dp12;
                } else {
                    stepDots[i].setBackgroundResource(R.drawable.bg_dot_idle);
                    lp.width = lp.height = dp8;
                }
                stepDots[i].setLayoutParams(lp);
            }
            // Pulse the active dot so screen feels alive
            startDotPulse(stepIndex);

            // Chips: compact, high contrast — dark bg + white text + teal border
            if (chipGroupCompleted != null) {
                chipGroupCompleted.removeAllViews();
                int teal  = ContextCompat.getColor(ProvisionLanding.this, R.color.colorPrimary);
                int white = 0xFFFFFFFF;
                for (int i = 0; i < stepIndex; i++) {
                    Chip chip = new Chip(ProvisionLanding.this);
                    chip.setText(STEP_TITLES[i] + " ✓");
                    chip.setTextSize(10f);
                    chip.setChipBackgroundColor(ColorStateList.valueOf(0xFF0A1A0A));
                    chip.setTextColor(white);
                    chip.setChipStrokeColor(ColorStateList.valueOf(teal));
                    chip.setChipStrokeWidth(1f);
                    chip.setChipMinHeight(28f);
                    chip.setChipStartPadding(14f);
                    chip.setChipEndPadding(14f);
                    chip.setTextStartPadding(4f);
                    chip.setTextEndPadding(4f);
                    chip.setChipIconVisible(false);
                    chip.setCheckedIconVisible(false);
                    chip.setCloseIconVisible(false);
                    chip.setEnsureMinTouchTargetSize(false);
                    chip.setClickable(false);
                    chip.setFocusable(false);
                    chipGroupCompleted.addView(chip);
                }
            }
        });
    }

    // ── Active dot pulse ──────────────────────────────────────────────────────
    private final Handler dotPulseHandler = new Handler(Looper.getMainLooper());
    private Runnable dotPulseRunnable;

    private void startDotPulse(int stepIndex) {
        stopDotPulse();
        if (stepIndex < 0 || stepIndex >= stepDots.length) return;
        View dot = stepDots[stepIndex];
        if (dot == null) return;
        dotPulseRunnable = new Runnable() {
            @Override public void run() {
                if (dot == null) return;
                // Alpha only — no scale so dot stays perfectly circular
                dot.animate()
                        .alpha(0.25f)
                        .setDuration(500)
                        .withEndAction(() -> dot.animate()
                                .alpha(1f)
                                .setDuration(500)
                                .withEndAction(() -> dotPulseHandler.postDelayed(dotPulseRunnable, 100))
                                .start())
                        .start();
            }
        };
        dotPulseHandler.post(dotPulseRunnable);
    }

    private void stopDotPulse() {
        dotPulseHandler.removeCallbacksAndMessages(null);
        dotPulseRunnable = null;
        for (View d : stepDots) {
            if (d != null) { d.setAlpha(1f); }
        }
    }

    private void resetFocusView() {
        stopDotPulse();
        currentStepIndex = 0;
        if (arcProgress != null) {
            arcProgress.setProgress(0);
            // Re-apply the teal tint directly — clearColorFilter on a mutated drawable
            // is unreliable; the displayed drawable keeps the old red tint from error state.
            arcProgress.setProgressTintList(
                    ColorStateList.valueOf(ContextCompat.getColor(this, R.color.colorPrimary)));
            arcProgress.setProgressBackgroundTintList(
                    ColorStateList.valueOf(0xFF222222));
        }
        if (tvStepNumber != null) {
            tvStepNumber.setText("1");
            tvStepNumber.setTextColor(ContextCompat.getColor(this, R.color.colorPrimary));
        }
        if (tvStepTitle != null)    tvStepTitle.setText(STEP_TITLES[0]);
        if (tvStepSubtitle != null) {
            tvStepSubtitle.setText(STEP_SUBTITLES[0]);
            tvStepSubtitle.setTextColor(ContextCompat.getColor(this, R.color.colorAccent));
        }
        if (chipGroupCompleted != null) chipGroupCompleted.removeAllViews();
        for (View d : stepDots) {
            if (d != null) d.setBackgroundResource(R.drawable.bg_dot_idle);
        }
        // Restore arc_frame and other elements hidden by success state
        View arcFrame = containerProvision == null ? null : containerProvision.findViewById(R.id.arc_frame);
        if (arcFrame != null) arcFrame.setVisibility(View.VISIBLE);
        View dotRow = containerProvision == null ? null : containerProvision.findViewById(R.id.dot_row);
        if (dotRow != null) dotRow.setVisibility(View.VISIBLE);
        View chipGroup = containerProvision == null ? null : containerProvision.findViewById(R.id.chip_group_completed);
        if (chipGroup != null) chipGroup.setVisibility(View.VISIBLE);
        View stepTitle = containerProvision == null ? null : containerProvision.findViewById(R.id.tv_step_title);
        if (stepTitle != null) stepTitle.setVisibility(View.VISIBLE);
        View stepSub = containerProvision == null ? null : containerProvision.findViewById(R.id.tv_step_subtitle);
        if (stepSub != null) stepSub.setVisibility(View.VISIBLE);
    }

    private void startProvisionSteps() {
        Log.d(TAG, "Selected AP: " + selectedSsid);
        if (provisionManager.getEfactorDevice() != null) {
            receivedNodeId = provisionManager.getEfactorDevice().getDeviceId();
            doStep1();
        } else {
            Log.e(TAG, "Device not ready — cannot provision");
            transitionTo(Phase.ERROR);
        }
    }

    // Steps mirror ProvisionActivity exactly — only UI references changed
    private void doStep1() { tick1.setVisibility(View.GONE); progress1.setVisibility(View.VISIBLE); updateFocusStep(0); associateDevice(); }
    private void doStep2() { tick1.setImageResource(R.drawable.ic_checkbox_on); tick1.setVisibility(View.VISIBLE); progress1.setVisibility(View.GONE); tick2.setVisibility(View.GONE); progress2.setVisibility(View.VISIBLE); updateFocusStep(1); }
    private void doStep3() { tick2.setImageResource(R.drawable.ic_checkbox_on); tick2.setVisibility(View.VISIBLE); progress2.setVisibility(View.GONE); updateFocusStep(2); }
    private void doStep4() { tick3.setImageResource(R.drawable.ic_checkbox_on); progress3.setVisibility(View.GONE); progress4.setVisibility(View.VISIBLE); updateFocusStep(3); }
    private void doStep5() { progress4.setVisibility(View.GONE); tick4.setImageResource(R.drawable.ic_checkbox_on); tick5.setVisibility(View.GONE); progress5.setVisibility(View.VISIBLE); updateFocusStep(4); }
    private void doStep6() { tick5.setImageResource(R.drawable.ic_checkbox_on); tick5.setVisibility(View.VISIBLE); progress5.setVisibility(View.GONE); tick6.setVisibility(View.GONE); progress6.setVisibility(View.VISIBLE); updateFocusStep(5); }
    private void doStep7(boolean successInStep2) {
        if (successInStep2) { tick6.setImageResource(R.drawable.ic_checkbox_on); tick6.setVisibility(View.VISIBLE); progress6.setVisibility(View.GONE); }
        else { error_flag4 = true; progress6.setVisibility(View.VISIBLE); }
        tick7.setVisibility(View.GONE); progress7.setVisibility(View.VISIBLE);
        updateFocusStep(6);
        provHandler.postDelayed(addDeviceTask, ADD_DEVICE_REQ_TIME);
    }
    private void doStep8() { tick7.setImageResource(R.drawable.ic_checkbox_on); tick7.setVisibility(View.VISIBLE); progress7.setVisibility(View.GONE); tick8.setVisibility(View.GONE); progress8.setVisibility(View.VISIBLE); updateFocusStep(7); }
    private void doStep9() {
        Log.d(TAG, "doStep9 — node: " + receivedNodeId);
        tick9.setVisibility(View.GONE); progress9.setVisibility(View.VISIBLE);
        updateFocusStep(8);
        nodeStatusPollingDone = false;
        provHandler.postDelayed(nodeStatusReqFailed, NODE_STATUS_REQ_TIME);
        apiManager.FETCHNODE(receivedNodeId, new ApiLibResponseListener() {
            @Override public void onSuccess(Bundle data) {
                if (!nodeStatusPollingDone) provHandler.postDelayed(getNodeStatusTask, 1000);
            }
            @Override public void onResponseFailure(Bundle e) {
                if (!nodeStatusPollingDone) provHandler.postDelayed(getNodeStatusTask, 1000);
            }
            @Override public void onNetworkFailure(Bundle e) {
                if (!nodeStatusPollingDone) provHandler.postDelayed(getNodeStatusTask, 1000);
            }
        });
    }

    private void sessionInitSuccess() {
        Log.d(TAG, "sessionInitSuccess");
        runOnUiThread(this::doStep2);
    }
    private void applyWifiConfig() {
        Log.d(TAG, "applyWifiConfig");
        runOnUiThread(this::doStep5);
    }

    private void provision() {
        Log.d(TAG, "provision() SSID=" + selectedSsid);
        provisionManager.getEfactorDevice().provision(selectedSsid, selectedPassword,
                new ProvisionListener() {
                    @Override public void createSessionFailed(Exception e) {
                        Log.e(TAG, "createSessionFailed: " + (e != null ? e.getMessage() : "null"));
                        runOnUiThread(() -> {
                            // Show proper error dialog — not just a Toast — so Retry works
                            showProvisionErrorDialog(
                                    "E106",
                                    "Couldn't connect to device.",
                                    "Stay near (2–3 m), toggle Wi-Fi, disable hotspot/VPN."
                            );
                        });
                    }
                    @Override public void wifiConfigSent() {
                        runOnUiThread(ProvisionLanding.this::doStep4);
                    }
                    @Override public void wifiConfigFailed(Exception e) {
                        runOnUiThread(() -> {
                            tick5.setImageResource(R.drawable.ic_error);
                            tick5.setVisibility(View.VISIBLE);
                            progress5.setVisibility(View.GONE);
                            tvErrAtStep6.setVisibility(View.VISIBLE);
                            tvErrAtStep6.setText(R.string.error_prov_step_2);
                            hideProvisionLoading();
                        });
                    }
                    @Override public void wifiConfigApplied() {
                        runOnUiThread(ProvisionLanding.this::doStep6);
                    }
                    @Override public void wifiConfigApplyFailed(Exception e) {
                        runOnUiThread(() -> {
                            tick5.setImageResource(R.drawable.ic_error);
                            tick5.setVisibility(View.VISIBLE);
                            progress5.setVisibility(View.GONE);
                            tvErrAtStep6.setVisibility(View.VISIBLE);
                            tvErrAtStep6.setText(R.string.error_prov_step_2);
                            hideProvisionLoading();
                        });
                    }
                    @Override public void provisioningFailedFromDevice(
                            EfactorConstants.ProvisionFailureReason reason) {
                        runOnUiThread(() -> {
                            switch (reason) {
                                case AUTH_FAILED:
                                    tvErrAtStep6.setText(R.string.error_authentication_failed);
                                    error_flag1 = true;
                                    displayFailureAtStep2();
                                    break;
                                case NETWORK_NOT_FOUND:
                                    tvErrAtStep6.setText(R.string.error_network_not_found);
                                    error_flag2 = true;
                                    displayFailureAtStep2();
                                    break;
                                case DEVICE_DISCONNECTED:
                                    error_flag3 = true;
                                    doStep7(false);
                                    break;
                                case UNKNOWN:
                                    tvErrAtStep6.setText(R.string.error_prov_step_3);
                                    error_flag8 = true;
                                    displayFailureAtStep2();
                                    break;
                            }
                        });
                    }
                    @Override public void deviceProvisioningSuccess() {
                        runOnUiThread(() -> {
                            isProvisioningCompleted = true;
                            doStep7(true);
                        });
                    }
                    @Override public void onProvisioningFailed(Exception e) {
                        runOnUiThread(() -> doStep7(false));
                    }
                });
    }

    private void displayFailureAtStep2() {
        tick6.setImageResource(R.drawable.ic_error);
        tick6.setVisibility(View.VISIBLE);
        progress6.setVisibility(View.GONE);
        tvErrAtStep6.setVisibility(View.VISIBLE);
        hideProvisionLoading();
    }

    private void associateDevice() {
        Log.d(TAG, "associateDevice");
        SharedPreferences prefs = getSharedPreferences(
                AppConstants.EFACTOR_PREFERENCES, Context.MODE_PRIVATE);
        String userName = prefs.getString(AppConstants.KEY_USER_NAME, "");
        EfactorDevice device = provisionManager.getEfactorDevice();
        if (device == null) { Log.e(TAG, "associateDevice: device null"); return; }
        device.sendDataToCustomEndPoint(userName, new ResponseListener() {
            @Override public void onSuccess(byte[] returnData) {
                runOnUiThread(ProvisionLanding.this::doStep3);
                processDetails(returnData);
            }
            @Override public void onFailure(Exception e) {
                Log.e(TAG, "sendDataToCustomEndPoint failed: " + e.getMessage());
                runOnUiThread(() -> {
                    tick1.setImageResource(R.drawable.ic_error);
                    tick1.setVisibility(View.VISIBLE);
                    progress1.setVisibility(View.GONE);
                    tvErrAtStep1.setVisibility(View.VISIBLE);
                    error_flag9 = true;
                    tvErrAtStep1.setText("Failed to connect to device, try again!");
                    hideProvisionLoading();
                });
            }
        });
    }

    private void processDetails(byte[] responseData) {
        try {
            String decoded = new String(responseData);
            String[] parts = decoded.split("\\|");
            if (parts.length == 2) {
                receivedNodeId = parts[0];
                secretKey      = parts[1];
                provision();
            } else {
                Log.e(TAG, "Invalid response format: " + decoded);
                runOnUiThread(() -> {
                    tick2.setImageResource(R.drawable.ic_error);
                    tick2.setVisibility(View.VISIBLE);
                    progress2.setVisibility(View.GONE);
                    tvErrAtStep2.setVisibility(View.VISIBLE);
                    tvErrAtStep2.setText("User device configuration failed, try again");
                    error_flag10 = true;
                    hideProvisionLoading();
                });
            }
        } catch (Exception e) {
            e.printStackTrace();
            runOnUiThread(() -> {
                tick2.setImageResource(R.drawable.ic_error);
                tick2.setVisibility(View.VISIBLE);
                progress2.setVisibility(View.GONE);
                tvErrAtStep2.setVisibility(View.VISIBLE);
                error_flag10 = true;
                tvErrAtStep2.setText("User device configuration failed, try again");
                hideProvisionLoading();
            });
        }
    }

    private void addDeviceToCloud(final ApiLibResponseListener listener) {
        Log.d(TAG, "addDeviceToCloud count=" + addDeviceReqCount);
        EfactorDeviceOperationRequest req = new EfactorDeviceOperationRequest();
        req.setDeviceId(receivedNodeId);
        req.setNodeId(receivedNodeId);
        req.setSecretKey(secretKey);
        apiManager.ADD(req, new ApiLibResponseListener() {
            @Override public void onSuccess(Bundle r)               { listener.onSuccess(r); }
            @Override public void onResponseFailure(Bundle e)       { listener.onResponseFailure(e); }
            @Override public void onNetworkFailure(Bundle e)        { listener.onNetworkFailure(e); }
        });
    }

    private final Runnable addDeviceTask = new Runnable() {
        @Override public void run() {
            if (addDeviceGaveUp) return;
            addDeviceReqCount++;
            addDeviceToCloud(new ApiLibResponseListener() {
                @Override public void onSuccess(Bundle data) {
                    if (addDeviceGaveUp) return;
                    runOnUiThread(ProvisionLanding.this::doStep8);
                }
                @Override public void onResponseFailure(Bundle e) {
                    if (addDeviceGaveUp) return;
                    if (addDeviceReqCount >= 10) {
                        addDeviceGaveUp = true;
                        runOnUiThread(() -> {
                            tick7.setImageResource(R.drawable.ic_error);
                            tick7.setVisibility(View.VISIBLE);
                            progress7.setVisibility(View.GONE);
                            tvErrAtStep7.setVisibility(View.VISIBLE);
                            tvErrAtStep7.setText(R.string.error_prov_step_3);
                            error_flag7 = true;
                            hideProvisionLoading();
                        });
                    } else {
                        provHandler.removeCallbacks(addDeviceTask);
                        provHandler.postDelayed(addDeviceTask, ADD_DEVICE_REQ_TIME);
                    }
                }
                @Override public void onNetworkFailure(Bundle e) {
                    if (addDeviceGaveUp) return;
                    if (addDeviceReqCount >= 10) {
                        addDeviceGaveUp = true;
                        runOnUiThread(() -> {
                            tick7.setImageResource(R.drawable.ic_error);
                            tick7.setVisibility(View.VISIBLE);
                            progress7.setVisibility(View.GONE);
                            tvErrAtStep7.setVisibility(View.VISIBLE);
                            tvErrAtStep7.setText(R.string.error_prov_step_3);
                            error_flag6 = true;
                            hideProvisionLoading();
                        });
                    } else {
                        provHandler.removeCallbacks(addDeviceTask);
                        provHandler.postDelayed(addDeviceTask, ADD_DEVICE_REQ_TIME);
                    }
                }
            });
        }
    };

    private final Runnable getNodeStatusTask = new Runnable() {
        @Override public void run() {
            if (isFinishing() || nodeStatusPollingDone) return;
            EfactorDeviceOperationRequest req = new EfactorDeviceOperationRequest();
            req.setDeviceId(receivedNodeId);
            req.setNodeId(receivedNodeId);
            apiManager.GET_CONNECTIVITY_STATUS(req, new ApiLibResponseListener() {
                @Override public void onSuccess(Bundle data) {
                    runOnUiThread(() -> {
                        boolean nodeStatus = data.getBoolean("nodeStatus", false);
                        long    timeStamp  = data.getLong("timestamp", 0);
                        if (nodeStatus) {
                            if (timeStamp != 0) {
                                String tzId = TimeZone.getDefault().getID();
                                EfactorDeviceOperationRequest tzReq = new EfactorDeviceOperationRequest();
                                tzReq.setDeviceId(receivedNodeId);
                                tzReq.setNodeId(receivedNodeId);
                                tzReq.setTime_zone(tzId);
                                apiManager.SET_LOCATION_TIMEZONE(tzReq, new ApiLibResponseListener() {
                                    @Override public void onSuccess(Bundle d) {
                                        runOnUiThread(() -> {
                                            if (nodeStatusPollingDone) return;
                                            nodeStatusPollingDone = true;
                                            provHandler.removeCallbacks(nodeStatusReqFailed);
                                            provHandler.removeCallbacks(getNodeStatusTask);
                                            tick9.setImageResource(R.drawable.ic_checkbox_on);
                                            tick9.setVisibility(View.VISIBLE);
                                            progress9.setVisibility(View.GONE);
                                            transitionTo(Phase.SUCCESS);
                                        });
                                    }
                                    @Override public void onResponseFailure(Bundle e) {
                                        runOnUiThread(() -> {
                                            tick9.setImageResource(R.drawable.ic_alert);
                                            tick9.setVisibility(View.VISIBLE);
                                            progress9.setVisibility(View.GONE);
                                            hideProvisionLoading();
                                        });
                                    }
                                    @Override public void onNetworkFailure(Bundle e) {
                                        runOnUiThread(() -> {
                                            tick9.setImageResource(R.drawable.ic_alert);
                                            tick9.setVisibility(View.VISIBLE);
                                            progress9.setVisibility(View.GONE);
                                            hideProvisionLoading();
                                        });
                                    }
                                });
                            } else {
                                tick9.setImageResource(R.drawable.ic_checkbox_on);
                                tick9.setVisibility(View.VISIBLE);
                                progress9.setVisibility(View.GONE);
                                provHandler.removeCallbacks(nodeStatusReqFailed);
                                transitionTo(Phase.SUCCESS);
                            }
                        } else {
                            if (!nodeStatusPollingDone) {
                                provHandler.removeCallbacks(getNodeStatusTask);
                                provHandler.postDelayed(getNodeStatusTask, 2000);
                            }
                        }
                    });
                }
                @Override public void onResponseFailure(Bundle e) {
                    if (!nodeStatusPollingDone) { provHandler.removeCallbacks(getNodeStatusTask); provHandler.postDelayed(getNodeStatusTask, 2000); }
                }
                @Override public void onNetworkFailure(Bundle e) {
                    if (!nodeStatusPollingDone) { provHandler.removeCallbacks(getNodeStatusTask); provHandler.postDelayed(getNodeStatusTask, 2000); }
                }
            });
        }
    };

    private final Runnable nodeStatusReqFailed = () -> {
        if (isFinishing() || isDestroyed()) return;
        Log.d(TAG, "Node status polling timed out");
        nodeStatusPollingDone = true;
        provHandler.removeCallbacks(getNodeStatusTask);
        runOnUiThread(() -> {
            tick9.setImageResource(R.drawable.ic_alert);
            tick9.setVisibility(View.VISIBLE);
            progress9.setVisibility(View.GONE);
            error_flag5 = true;
            hideProvisionLoading();
        });
    };

    private void hideProvisionLoading() {
        runOnUiThread(() -> {
            handleProvisionError();
            btnOk.setEnabled(true);
            btnOk.setAlpha(1f);
        });
    }

    private void handleProvisionError() {
        String code = null, shortMsg = null, longMsg = null;
        if      (error_flag1)  { code="E101"; shortMsg="Incorrect Wi-Fi password.";        longMsg="Re-enter the Wi-Fi password (check Caps/spaces)."; }
        else if (error_flag2)  { code="E102"; shortMsg="Weak or unstable Wi-Fi.";           longMsg="Move closer to the router. Prefer 2.4 GHz."; }
        else if (error_flag3)  { code="E103"; shortMsg="Device not ready for setup.";       longMsg="Ensure power ON. Restart or reset per manual."; }
        else if (error_flag6)  { code="E104"; shortMsg="No internet on phone.";             longMsg="Enable mobile data or connect to Wi-Fi. Disable VPN."; }
        else if (error_flag7)  { code="E105"; shortMsg="Server configuration failed.";      longMsg="May be temporary. Retry in a moment."; }
        else if (error_flag9)  { code="E106"; shortMsg="Couldn't connect to device.";       longMsg="Stay near (2–3 m), toggle Wi-Fi, disable hotspot/VPN."; }
        else if (error_flag10) { code="E107"; shortMsg="User setup step failed.";           longMsg="Restart app & device, then retry."; }
        else if (error_flag8)  { code="E109"; shortMsg="Unknown error.";                   longMsg="Restart device & app. If it persists, contact support."; }
        else if (error_flag5)  { code="E110"; shortMsg="Device unreachable.";              longMsg="Verify the Wi-Fi network has a stable internet connection."; }
        if (error_flag4 && error_flag5) { code="E111"; shortMsg="Incorrect Wi-Fi password."; longMsg="Re-enter the Wi-Fi password (check Caps/spaces).";
            tick6.setImageResource(R.drawable.ic_error); tick6.setVisibility(View.VISIBLE); progress6.setVisibility(View.GONE);
            tick9.setImageResource(R.drawable.ic_error); tick9.setVisibility(View.VISIBLE); progress9.setVisibility(View.GONE); }

        if (code != null) {
            stopDotPulse();
            // Turn arc red using TintList — reversible, no mutation side effects
            if (arcProgress != null) {
                arcProgress.setProgressTintList(
                        ColorStateList.valueOf(ContextCompat.getColor(this, R.color.color_err_text)));
            }
            if (tvStepSubtitle != null) {
                tvStepSubtitle.setTextColor(ContextCompat.getColor(this, R.color.color_err_text));
                tvStepSubtitle.setText(shortMsg);
            }
            if (tvStepNumber != null)
                tvStepNumber.setTextColor(ContextCompat.getColor(this, R.color.color_err_text));
            if (currentStepIndex < stepDots.length && stepDots[currentStepIndex] != null)
                stepDots[currentStepIndex].setBackgroundColor(
                        ContextCompat.getColor(this, R.color.color_err_text));
            tvProvError.setText("[" + code + "] " + shortMsg);
            tvProvError.setVisibility(View.VISIBLE);
            txtOkBtn.setText("Retry");
            if (layoutBtn != null)
                layoutBtn.setBackgroundColor(ContextCompat.getColor(this, R.color.color_err_text));
            showProvisionErrorDialog(code, shortMsg, longMsg);        } else {
            if (progress_flag5) {
                tick5.setImageResource(R.drawable.ic_checkbox_on);
                tick5.setVisibility(View.VISIBLE);
                progress5.setVisibility(View.GONE);
            }
            tick6.setImageResource(R.drawable.ic_checkbox_on);
            tick6.setVisibility(View.VISIBLE);
            progress6.setVisibility(View.GONE);
        }
        cloudManager.setProvisionStarted(false);
    }

    private void showProvisionErrorDialog(String code, String shortMsg, String longMsg) {
        if (isFinishing() || isDestroyed()) return;
        if (activeErrorDialog != null && activeErrorDialog.isShowing()) {
            activeErrorDialog.dismiss();
            activeErrorDialog = null;
        }
        View dv = getLayoutInflater().inflate(R.layout.custom_dialog, null);
        TextView tvDTitle = dv.findViewById(R.id.tvTitle);
        TextView tvDCode  = dv.findViewById(R.id.tvCodeAndShort);
        TextView tvDPts   = dv.findViewById(R.id.tvPoints);
        TextView btnRetry = dv.findViewById(R.id.btnRetry);
        TextView btnHelp  = dv.findViewById(R.id.btnTroubleshoot);
        tvDTitle.setText("Setup error");
        tvDCode.setText("[" + code + "] " + shortMsg);
        tvDPts.setText(longMsg);
        btnRetry.setText("RETRY");
        btnHelp.setText("HELP");
        activeErrorDialog = new AlertDialog.Builder(this)
                .setView(dv).setCancelable(true).create();
        if (activeErrorDialog.getWindow() != null)
            activeErrorDialog.getWindow().setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
        btnRetry.setOnClickListener(v -> {
            if (activeErrorDialog != null) { activeErrorDialog.dismiss(); activeErrorDialog = null; }
            retryProvision();
        });
        btnHelp.setOnClickListener(v -> openTroubleshoot(code));
        activeErrorDialog.show();
    }

    /**
     * Full retry: dismiss dialog, reset device + state, go to WIFI_PICK (not SCAN)
     * so user re-confirms network — fixes "Selected AP: null" on retry.
     */
    private void retryProvision() {
        Log.d(TAG, "retryProvision — resetting to WIFI_PICK");

        provHandler.removeCallbacks(addDeviceTask);
        provHandler.removeCallbacks(getNodeStatusTask);
        provHandler.removeCallbacks(nodeStatusReqFailed);
        cloudManager.setProvisionStarted(false);

        if (layoutBtn != null)
            layoutBtn.setBackgroundColor(ContextCompat.getColor(this, R.color.colorPrimary));

        // Stop ping and disconnect — this calls disableOnlyWifiNetwork() which unbinds
        // the process from the SoftAP network and unregisters the networkCallback.
        if (provisionManager.getEfactorDevice() != null) {
            provisionManager.getEfactorDevice().stopPingLocal();
            provisionManager.getEfactorDevice().disconnectDevice();
        }

        // Clear credentials — user must re-pick network (prevents null AP bug)
        resetScanState();
        selectedSsid     = null;
        selectedPassword = null;

        if (!EventBus.getDefault().isRegistered(this))
            EventBus.getDefault().register(this);

        // On Android 10+, WifiNetworkSpecifier requests have OS-level release latency.
        // If we call createEfactorDevice + requestNetwork immediately after disconnect,
        // the new requestNetwork gets onUnavailable() because Android hasn't released
        // the previous network specifier yet. 3s gives the OS time to release it.
        long releaseDelay = (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ? 3000L : 500L;

        new Handler(Looper.getMainLooper()).postDelayed(() -> {
            provisionManager.createEfactorDevice(
                    EfactorConstants.TransportType.TRANSPORT_SOFTAP,
                    EfactorConstants.SecurityType.SECURITY_1,
                    pop);
            provisionManager.getEfactorDevice().setProofOfPossession(pop);
            provisionManager.getEfactorDevice().setDeviceId(pop);

            // Go to WIFI_PICK so user re-selects network before scanning
            transitionTo(Phase.WIFI_PICK);
        }, releaseDelay);
    }

    private void onOkClicked() {
        provHandler.removeCallbacks(addDeviceTask);
        provHandler.removeCallbacks(getNodeStatusTask);
        provHandler.removeCallbacks(nodeStatusReqFailed);
        if (provisionManager.getEfactorDevice() != null)
            provisionManager.getEfactorDevice().disconnectDevice();
        cloudManager.setProvisionStarted(false);
        Intent result = new Intent();
        result.putExtra("status", "success");
        result.putExtra("ssid", selectedSsid);
        result.putExtra("device_ssid", expectedSoftApSsid);
        result.putExtra("node_id", receivedNodeId);
        result.putExtra("message", "DEVICE IS CONNECTED SUCCESSFULLY");
        setResult(RESULT_OK, result);
        finish();
    }

    private void openTroubleshoot(String code) {
        try {
            EfactorNode node = EfactorLibraryManager.getInstance().getEfactorNode(receivedNodeId);
            if (node == null) return;
            String url = node.getRelatedVideos();
            if (TextUtils.isEmpty(url)) return;
            // Open in browser as fallback if UserGuideHubActivity is not available
            Intent intent = new Intent(android.content.Intent.ACTION_VIEW,
                    android.net.Uri.parse(url));
            startActivity(intent);
        } catch (Exception e) {
            Log.e(TAG, "openTroubleshoot error: " + e.getMessage());
        }
    }

    // =========================================================================
    // EventBus — single subscriber for ALL events in the merged flow
    // =========================================================================

    @Subscribe(threadMode = ThreadMode.MAIN)
    public void onDeviceConnectionEvent(DeviceConnectionEvent event) {
        Log.d(TAG, "DeviceConnectionEvent: " + event.getEventType());
        switch (event.getEventType()) {

            case EfactorConstants.EVENT_DEVICE_CONNECTED:
                // P2P connected → check capabilities → go to WiFi pick
                stopConnectTimeout();
                stageHandler.removeCallbacks(stageTicker);
                checkDeviceCapabilitiesAndAdvance();
                break;

            case EfactorConstants.EVENT_DEVICE_CONNECTION_FAILED:
                Toast.makeText(this, R.string.error_device_connect_failed, Toast.LENGTH_SHORT).show();
                stopConnectTimeout();
                stageHandler.removeCallbacks(stageTicker);
                if (!p2pRetryAttempted && scanListReady) {
                    p2pRetryAttempted = true;
                    connectingStarted = false;
                    connectToDevice(); // one retry
                } else {
                    connectingStarted = false;
                    connectRequested  = false;
                    transitionTo(Phase.TIMEOUT);
                }
                break;

            case EfactorConstants.EVENT_DEVICE_SESSION_ESTABLISHED:
                sessionInitSuccess();
                break;

            case EfactorConstants.EVENT_APPLY_WIFI_CONFIG:
                applyWifiConfig();
                break;

            case EfactorConstants.EVENT_APPLY_WIFI_CONFIG_FAILED:
                progress_flag5 = true;
                runOnUiThread(() -> doStep7(false));
                break;

            case EfactorConstants.EVENT_DEVICE_DISCONNECTED:
                if (currentPhase == Phase.P2P) {
                    stopConnectTimeout();
                    stageHandler.removeCallbacks(stageTicker);
                    connectingStarted = false;
                    connectRequested  = false;
                    transitionTo(Phase.TIMEOUT);
                } else if (currentPhase == Phase.PROVISION && !isProvisioningCompleted) {
                    Log.w(TAG, "Device disconnected mid-provision");
                    showAlertForDeviceDisconnected();
                }
                break;

            case EfactorConstants.EVENT_DEVICE_ADDED:
                if (!addDeviceGaveUp) {
                    tick8.setImageResource(R.drawable.ic_checkbox_on);
                    tick8.setVisibility(View.VISIBLE);
                    progress8.setVisibility(View.GONE);
                    doStep9();
                }
                break;

            case EfactorConstants.EVENT_ADD_DEVICE_TIME_OUT:
                if (!addDeviceGaveUp) {
                    tick8.setImageResource(R.drawable.ic_alert);
                    tick8.setVisibility(View.VISIBLE);
                    progress8.setVisibility(View.GONE);
                    doStep9();
                }
                break;
        }
    }

    @Subscribe(threadMode = ThreadMode.MAIN)
    public void onUpdateEvent(UpdateEvent event) {
        Log.d(TAG, "UpdateEvent: " + event.getEventType());
        switch (event.getEventType()) {
            case EVENT_DEVICE_ADDED:
                if (!addDeviceGaveUp) {
                    tick8.setImageResource(R.drawable.ic_checkbox_on);
                    tick8.setVisibility(View.VISIBLE);
                    progress8.setVisibility(View.GONE);
                    doStep9();
                }
                break;
            case EVENT_ADD_DEVICE_TIME_OUT:
                if (!addDeviceGaveUp) {
                    tick8.setImageResource(R.drawable.ic_alert);
                    tick8.setVisibility(View.VISIBLE);
                    progress8.setVisibility(View.GONE);
                    doStep9();
                }
                break;
        }
    }

    // =========================================================================
    // Capability check after P2P connected
    // =========================================================================

    private void checkDeviceCapabilitiesAndAdvance() {
        // versionInfo is set by getCapabilitiesTask only after transport.sendConfigData() succeeds.
        // That means bindProcessToNetwork(network) is already active and the SoftAP HTTP server
        // is already responding. Transition to PROVISION immediately — no artificial delay needed.
        String versionInfo = provisionManager.getEfactorDevice().getVersionInfo();
        if (!TextUtils.isEmpty(pop) && versionInfo != null) {
            transitionTo(Phase.PROVISION);
        }
    }

    // =========================================================================
    // Disconnect mid-provision dialog
    // =========================================================================

    private void showAlertForDeviceDisconnected() {
        if (isFinishing() || isDestroyed()) return;
        new AlertDialog.Builder(this)
                .setCancelable(false)
                .setTitle(R.string.error_title)
                .setMessage(R.string.dialog_msg_ble_device_disconnection)
                .setPositiveButton("Retry", (d, w) -> { d.dismiss(); retryProvision(); })
                .setNegativeButton(R.string.btn_cancel, (d, w) -> { d.dismiss(); finish(); })
                .show();
    }

    // =========================================================================
    // Wi-Fi scan broadcast receiver
    // =========================================================================

    private void registerWifiScanReceiver() {
        if (wifiScanReceiver != null) return;
        wifiScanReceiver = new BroadcastReceiver() {
            @Override public void onReceive(Context context, Intent intent) {
                if (ignoreScanBroadcasts) return;
                if (!WifiManager.SCAN_RESULTS_AVAILABLE_ACTION.equals(intent.getAction())) return;
                boolean updated = intent.getBooleanExtra(WifiManager.EXTRA_RESULTS_UPDATED, false);
                handleScanBroadcast(updated);
            }
        };
        registerReceiver(wifiScanReceiver,
                new IntentFilter(WifiManager.SCAN_RESULTS_AVAILABLE_ACTION));
    }

    private void unregisterWifiReceiverSafely() {
        try { if (wifiScanReceiver != null) unregisterReceiver(wifiScanReceiver); }
        catch (Exception ignored) {}
        wifiScanReceiver = null;
    }

    // =========================================================================
    // Permissions & system dialogs
    // =========================================================================

    private boolean hasLocationPermission() {
        if (Build.VERSION.SDK_INT >= 29)
            return checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)
                    == PackageManager.PERMISSION_GRANTED;
        return checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION)
                == PackageManager.PERMISSION_GRANTED
                || checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)
                == PackageManager.PERMISSION_GRANTED;
    }

    private void requestLocationPermission() {
        String perm = Build.VERSION.SDK_INT >= 29
                ? Manifest.permission.ACCESS_FINE_LOCATION
                : Manifest.permission.ACCESS_COARSE_LOCATION;
        requestPermissions(new String[]{ perm }, REQUEST_FINE_LOCATION);
    }

    @Override
    public void onRequestPermissionsResult(int code, @NonNull String[] perms,
                                           @NonNull int[] grants) {
        super.onRequestPermissionsResult(code, perms, grants);
        if (code == REQUEST_FINE_LOCATION && hasLocationPermission()) {
            maybeStartWifiScan();
        }
    }

    @Override
    protected void onActivityResult(int req, int result, Intent data) {
        super.onActivityResult(req, result, data);
        switch (req) {
            case WIFI_SETTINGS_REQUEST:
                if (hasLocationPermission() && wifiManager.isWifiEnabled()) maybeStartWifiScan();
                else if (!wifiManager.isWifiEnabled()) showWifiNotEnabledDialog();
                break;
            case REQUEST_LOCATION_ENABLE:
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && isLocationEnabled())
                    maybeStartWifiScan();
                break;
        }
    }

    private boolean isLocationEnabled() {
        LocationManager lm = (LocationManager) getSystemService(Activity.LOCATION_SERVICE);
        try { if (lm.isProviderEnabled(LocationManager.GPS_PROVIDER)) return true; }
        catch (Exception ignored) {}
        try { if (lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) return true; }
        catch (Exception ignored) {}
        return false;
    }

    private void askForLocation() {
        new AlertDialog.Builder(this)
                .setCancelable(true)
                .setMessage(R.string.dialog_msg_for_gps)
                .setPositiveButton(R.string.btn_ok, (d, w) ->
                        startActivityForResult(new Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS),
                                REQUEST_LOCATION_ENABLE))
                .setNegativeButton(R.string.btn_cancel, (d, w) -> d.cancel())
                .show();
    }

    private void showWifiNotEnabledDialog() {
        new AlertDialog.Builder(this)
                .setCancelable(false)
                .setMessage("Wi-Fi was not enabled. Please enable it to proceed.")
                .setPositiveButton("Retry", (d, w) ->
                        startActivityForResult(new Intent(Settings.ACTION_WIFI_SETTINGS),
                                WIFI_SETTINGS_REQUEST))
                .setNegativeButton("Cancel", (d, w) -> { d.cancel(); finish(); })
                .show();
    }

    private void askToEnableWifi() {
        new AlertDialog.Builder(this)
                .setCancelable(false)
                .setTitle("Wi-Fi is Disabled")
                .setMessage("To proceed, Wi-Fi needs to be enabled.")
                .setPositiveButton("Enable", (d, w) ->
                        startActivityForResult(new Intent(Settings.ACTION_WIFI_SETTINGS),
                                WIFI_SETTINGS_REQUEST))
                .setNegativeButton(R.string.btn_cancel, (d, w) -> { d.cancel(); finish(); })
                .show();
    }
}