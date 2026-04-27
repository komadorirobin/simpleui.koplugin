-- module_app_launcher.lua — Simple UI (fork: komadorirobin)
-- Android app-launcher grid widget for the SimpleUI homescreen.
--
-- Shows a row of tappable app buttons (real app icon + label below).
-- Tapping a button launches the Android app.
--
-- Apps are configured in the APPS table below.  Each entry has:
--   label   — display name shown below the icon
--   abbr    — 1–3 character fallback shown as the icon if icon fetch fails
--   package — Android package name
--   action  — (optional) explicit intent action to use instead of getLaunchIntentForPackage
--
-- To add or remove apps, edit the APPS table and restart KOReader.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local ImageWidget     = require("ui/widget/imagewidget")
local InfoMessage     = require("ui/widget/infomessage")
local InputContainer  = require("ui/widget/container/inputcontainer")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local logger          = require("logger")
local Screen          = Device.screen

local UI     = require("sui_core")
local Config = require("sui_config")

local PAD = UI.PAD

-- ---------------------------------------------------------------------------
-- App icon cache — fetches icons via JNI, saves as PNG to disk
-- ---------------------------------------------------------------------------

local ICON_CACHE_DIR = "/sdcard/koreader/simpleui_icons"
-- In-memory cache: pkg -> path string (success) or false (failed/unavailable)
local _icon_mem_cache = {}

-- Renders the app icon for `pkg` into a PNG at ICON_CACHE_DIR/<pkg>.png.
-- Returns the file path on success, nil on failure.
local function _fetchIcon(pkg, sz)
    local ok, result = pcall(function()
        local android_mod = require("android")
        local ffi         = require("ffi")

        pcall(ffi.cdef, [[
            union jvalue_u {
                bool z; int8_t b; uint16_t c; int16_t s; int32_t i;
                int64_t j; float f; double d; void* l;
            };
        ]])

        local vm = android_mod.app.activity.vm
        local env_pp = ffi.new("JNIEnv*[1]")
        if vm[0].AttachCurrentThread(vm, env_pp, nil) ~= 0 then
            error("AttachCurrentThread failed")
        end
        local env = env_pp[0]

        local function jv(n)  return ffi.new("union jvalue_u[" .. n .. "]") end
        local function cv(a)  return ffi.cast("void*", a) end
        local function chk(l)
            if env[0].ExceptionCheck(env) ~= 0 then
                env[0].ExceptionClear(env)
                error(l .. " exception")
            end
        end

        local activity  = android_mod.app.activity.clazz
        local ActClass  = env[0].GetObjectClass(env, activity)

        -- getPackageManager()
        local mGetPM = env[0].GetMethodID(env, ActClass, "getPackageManager",
            "()Landroid/content/pm/PackageManager;")
        local pm = env[0].CallObjectMethod(env, activity, mGetPM)
        chk("getPackageManager"); if not pm then error("pm null") end

        -- pm.getApplicationIcon(pkg) -> Drawable
        local PMClass   = env[0].GetObjectClass(env, pm)
        local mGetIcon  = env[0].GetMethodID(env, PMClass, "getApplicationIcon",
            "(Ljava/lang/String;)Landroid/graphics/drawable/Drawable;")
        local a1 = jv(1); a1[0].l = env[0].NewStringUTF(env, pkg)
        local drawable = env[0].CallObjectMethodA(env, pm, mGetIcon, cv(a1))
        env[0].DeleteLocalRef(env, a1[0].l)
        chk("getApplicationIcon"); if not drawable then error("drawable null") end

        -- Bitmap.createBitmap(sz, sz, ARGB_8888)
        local BmpClass  = env[0].FindClass(env, "android/graphics/Bitmap")
        local CfgClass  = env[0].FindClass(env, "android/graphics/Bitmap$Config")
        local fARGB     = env[0].GetStaticFieldID(env, CfgClass, "ARGB_8888",
            "Landroid/graphics/Bitmap$Config;")
        local argb      = env[0].GetStaticObjectField(env, CfgClass, fARGB)
        local mCreate   = env[0].GetStaticMethodID(env, BmpClass, "createBitmap",
            "(IILandroid/graphics/Bitmap$Config;)Landroid/graphics/Bitmap;")
        local a3 = jv(3); a3[0].i = sz; a3[1].i = sz; a3[2].l = argb
        local bmp = env[0].CallStaticObjectMethodA(env, BmpClass, mCreate, cv(a3))
        chk("createBitmap"); if not bmp then error("bmp null") end

        -- Canvas(bmp)
        local CanClass  = env[0].FindClass(env, "android/graphics/Canvas")
        local mCan      = env[0].GetMethodID(env, CanClass, "<init>",
            "(Landroid/graphics/Bitmap;)V")
        local ac = jv(1); ac[0].l = bmp
        local canvas = env[0].NewObjectA(env, CanClass, mCan, cv(ac))
        chk("Canvas"); if not canvas then error("canvas null") end

        -- Fill entire bitmap with white first so corners outside the clip stay white
        local mDrawColor = env[0].GetMethodID(env, CanClass, "drawColor", "(I)V")
        local aDC = jv(1); aDC[0].i = -1  -- 0xFFFFFFFF = Color.WHITE
        env[0].CallVoidMethodA(env, canvas, mDrawColor, cv(aDC))
        chk("drawColor")

        -- Clip canvas to rounded rect so icon corners become transparent
        local corner_r  = sz * 0.22  -- ~22% of icon size
        local PathClass = env[0].FindClass(env, "android/graphics/Path")
        local mPathNew  = env[0].GetMethodID(env, PathClass, "<init>", "()V")
        local pathObj   = env[0].NewObjectA(env, PathClass, mPathNew, nil)
        chk("Path")
        local RectFClass = env[0].FindClass(env, "android/graphics/RectF")
        local mRectFNew  = env[0].GetMethodID(env, RectFClass, "<init>", "(FFFF)V")
        local aRF = jv(4); aRF[0].f=0; aRF[1].f=0; aRF[2].f=sz; aRF[3].f=sz
        local rectFObj   = env[0].NewObjectA(env, RectFClass, mRectFNew, cv(aRF))
        chk("RectF")
        local DirClass = env[0].FindClass(env, "android/graphics/Path$Direction")
        local fCW      = env[0].GetStaticFieldID(env, DirClass, "CW",
            "Landroid/graphics/Path$Direction;")
        local cwObj    = env[0].GetStaticObjectField(env, DirClass, fCW)
        local mAddRR   = env[0].GetMethodID(env, PathClass, "addRoundRect",
            "(Landroid/graphics/RectF;FFLandroid/graphics/Path$Direction;)V")
        local aARR = jv(4)
        aARR[0].l = rectFObj
        aARR[1].f = corner_r
        aARR[2].f = corner_r
        aARR[3].l = cwObj
        env[0].CallVoidMethodA(env, pathObj, mAddRR, cv(aARR))
        chk("addRoundRect")
        local mClipPath = env[0].GetMethodID(env, CanClass, "clipPath",
            "(Landroid/graphics/Path;)Z")
        local aCP = jv(1); aCP[0].l = pathObj
        env[0].CallBooleanMethodA(env, canvas, mClipPath, cv(aCP))
        chk("clipPath")
        env[0].DeleteLocalRef(env, pathObj)
        env[0].DeleteLocalRef(env, rectFObj)

        -- drawable.setBounds(0, 0, sz, sz)
        local DrawClass = env[0].GetObjectClass(env, drawable)
        local mBounds   = env[0].GetMethodID(env, DrawClass, "setBounds", "(IIII)V")
        local ab = jv(4); ab[0].i=0; ab[1].i=0; ab[2].i=sz; ab[3].i=sz
        env[0].CallVoidMethodA(env, drawable, mBounds, cv(ab))

        -- drawable.draw(canvas)
        local mDraw = env[0].GetMethodID(env, DrawClass, "draw",
            "(Landroid/graphics/Canvas;)V")
        local ad = jv(1); ad[0].l = canvas
        env[0].CallVoidMethodA(env, drawable, mDraw, cv(ad))
        chk("draw")

        -- Build output path; ensure parent dir via File.mkdirs()
        -- Suffix "_r" distinguishes rounded icons from any old flat cache files.
        local out_path  = ICON_CACHE_DIR .. "/" .. pkg .. "_rw.png"
        local FileClass = env[0].FindClass(env, "java/io/File")
        local mFileNew  = env[0].GetMethodID(env, FileClass, "<init>",
            "(Ljava/lang/String;)V")
        local jPath     = env[0].NewStringUTF(env, out_path)
        local afp = jv(1); afp[0].l = jPath
        local fileObj   = env[0].NewObjectA(env, FileClass, mFileNew, cv(afp))
        env[0].DeleteLocalRef(env, jPath)
        local mParent   = env[0].GetMethodID(env, FileClass, "getParentFile",
            "()Ljava/io/File;")
        local parentObj = env[0].CallObjectMethod(env, fileObj, mParent)
        if parentObj then
            local mMkdirs = env[0].GetMethodID(env, FileClass, "mkdirs", "()Z")
            env[0].CallBooleanMethod(env, parentObj, mMkdirs)
            env[0].DeleteLocalRef(env, parentObj)
        end

        -- FileOutputStream(file)
        local FOSClass  = env[0].FindClass(env, "java/io/FileOutputStream")
        local mFOSNew   = env[0].GetMethodID(env, FOSClass, "<init>",
            "(Ljava/io/File;)V")
        local afo = jv(1); afo[0].l = fileObj
        local fos = env[0].NewObjectA(env, FOSClass, mFOSNew, cv(afo))
        env[0].DeleteLocalRef(env, fileObj)
        chk("FileOutputStream"); if not fos then error("fos null") end

        -- bmp.compress(PNG, 100, fos)
        local CFClass   = env[0].FindClass(env, "android/graphics/Bitmap$CompressFormat")
        local fPNG      = env[0].GetStaticFieldID(env, CFClass, "PNG",
            "Landroid/graphics/Bitmap$CompressFormat;")
        local pngFmt    = env[0].GetStaticObjectField(env, CFClass, fPNG)
        local mCompress = env[0].GetMethodID(env, BmpClass, "compress",
            "(Landroid/graphics/Bitmap$CompressFormat;ILjava/io/OutputStream;)Z")
        local acp = jv(3); acp[0].l = pngFmt; acp[1].i = 100; acp[2].l = fos
        env[0].CallBooleanMethodA(env, bmp, mCompress, cv(acp))
        chk("compress")

        -- fos.close()
        local OsClass = env[0].FindClass(env, "java/io/OutputStream")
        local mClose  = env[0].GetMethodID(env, OsClass, "close", "()V")
        env[0].CallVoidMethod(env, fos, mClose)

        env[0].DeleteLocalRef(env, fos)
        env[0].DeleteLocalRef(env, bmp)
        env[0].DeleteLocalRef(env, canvas)
        env[0].DeleteLocalRef(env, drawable)

        return out_path
    end)

    if ok then
        local f = io.open(result, "rb")
        if f then f:close(); return result end
    end
    logger.warn("module_app_launcher: icon fetch failed for " .. pkg ..
        ": " .. tostring(result))
    return nil
end

-- Returns a cached icon path (fetching+saving on first call), or nil.
local function _getIconPath(pkg, sz)
    if _icon_mem_cache[pkg] ~= nil then
        return _icon_mem_cache[pkg] or nil
    end
    -- Check disk cache
    local disk_path = ICON_CACHE_DIR .. "/" .. pkg .. "_rw.png"
    local f = io.open(disk_path, "rb")
    if f then
        f:close()
        _icon_mem_cache[pkg] = disk_path
        return disk_path
    end
    -- Fetch from Android
    local path = _fetchIcon(pkg, sz)
    _icon_mem_cache[pkg] = path or false
    return path
end

-- ---------------------------------------------------------------------------
-- App list — edit here to add / remove / reorder apps
-- ---------------------------------------------------------------------------

local APPS = {
    { label = "Firefox",       abbr = "FF",  package = "org.mozilla.firefox"            },
    { label = "AirDroid",      abbr = "AD",  package = "com.sand.airdroid"              },
    { label = "Inställningar", abbr = "⚙",   package = "com.android.settings",           action = "android.settings.SETTINGS" },
    { label = "Play Butik",    abbr = "▶",   package = "com.android.vending"            },
    { label = "Files",         abbr = "📁",  package = "com.google.android.apps.nbu.files" },
}

-- ---------------------------------------------------------------------------
-- Dimensions
-- ---------------------------------------------------------------------------

local _BASE_ICON_SZ   = Screen:scaleBySize(52)
local _BASE_FRAME_PAD = Screen:scaleBySize(16)
local _BASE_CORNER_R  = Screen:scaleBySize(22)
local _BASE_LBL_SP    = Screen:scaleBySize(7)
local _BASE_LBL_H     = Screen:scaleBySize(20)
local _BASE_LBL_FS    = Screen:scaleBySize(9)

local _CLR_FRAME_BG   = Blitbuffer.gray(0.08)
local _CLR_TEXT       = Blitbuffer.COLOR_BLACK

local function _getDims(scale)
    scale = scale or 1.0
    local icon_sz   = math.max(16, math.floor(_BASE_ICON_SZ   * scale))
    local frame_pad = math.max(4,  math.floor(_BASE_FRAME_PAD * scale))
    local lbl_sp    = math.max(1,  math.floor(_BASE_LBL_SP    * scale))
    local lbl_h     = math.max(8,  math.floor(_BASE_LBL_H     * scale))
    return {
        icon_sz   = icon_sz,
        frame_pad = frame_pad,
        frame_sz  = icon_sz + frame_pad * 2,
        corner_r  = math.max(4, math.floor(_BASE_CORNER_R * scale)),
        lbl_sp    = lbl_sp,
        lbl_h     = lbl_h,
        lbl_fs    = math.max(6, math.floor(_BASE_LBL_FS * scale)),
        -- abbr font: large enough to fill roughly 60% of icon height
        abbr_fs   = math.max(8, math.floor(icon_sz * 0.50)),
    }
end

-- ---------------------------------------------------------------------------
-- Launch helper — JNI approach: PackageManager.getLaunchIntentForPackage
-- ---------------------------------------------------------------------------
-- On Android 14, os.execute("am start") is blocked by SELinux, and
-- Device:openLink creates Intent(ACTION_VIEW, Uri.parse(url)) which cannot
-- parse intent:// URIs.  The reliable path is to call JNI directly:
--   PackageManager.getLaunchIntentForPackage(pkg) → startActivity(intent)
-- KOReader exposes android.app.activity.vm (JavaVM*) and the full JNI
-- vtable via FFI, so we can make the call without any native code changes.

local function _launchApp(pkg, label, action)
    logger.dbg("module_app_launcher: launching " .. pkg)

    -- Feedback toast — visible immediately so the user knows the tap fired.
    UIManager:show(InfoMessage:new{
        text    = "Starting " .. label .. "…",
        timeout = 1.5,
    })

    -- ------------------------------------------------------------------ --
    -- Strategy 1: JNI via PackageManager.getLaunchIntentForPackage        --
    -- Uses *MethodA variants (jvalue[] array) to avoid LuaJIT varargs FFI --
    -- ------------------------------------------------------------------ --
    local ok_jni, jni_err = pcall(function()
        local ok_a, android_mod = pcall(require, "android")
        if not ok_a or not android_mod then
            error("android module not available")
        end
        logger.dbg("module_app_launcher: android module ok")

        local ffi = require("ffi")

        -- jvalue union — one slot per argument when using *MethodA calls.
        -- Define only once (pcall guards re-definition errors).
        pcall(ffi.cdef, [[
            union jvalue_u {
                bool     z;
                int8_t   b;
                uint16_t c;
                int16_t  s;
                int32_t  i;
                int64_t  j;
                float    f;
                double   d;
                void*    l;
            };
        ]])

        -- Attach the current (native/Lua) thread to the JVM.
        -- AttachCurrentThread is idempotent — safe to call even if already attached.
        local vm = android_mod.app.activity.vm
        logger.dbg("module_app_launcher: got vm")
        local env_pp = ffi.new("JNIEnv*[1]")
        local attach_ret = vm[0].AttachCurrentThread(vm, env_pp, nil)
        if attach_ret ~= 0 then
            error("AttachCurrentThread failed: " .. attach_ret)
        end
        local env = env_pp[0]
        logger.dbg("module_app_launcher: attached thread")

        -- The Activity instance (global JNI ref, safe across threads).
        local activity = android_mod.app.activity.clazz
        logger.dbg("module_app_launcher: got activity clazz")

        -- Activity class
        local ActivityClass = env[0].GetObjectClass(env, activity)
        if not ActivityClass then error("GetObjectClass(activity) failed") end

        -- getPackageManager()  — no args, use CallObjectMethod (no varargs issue)
        local mGetPM = env[0].GetMethodID(
            env, ActivityClass,
            "getPackageManager", "()Landroid/content/pm/PackageManager;")
        if not mGetPM then error("GetMethodID(getPackageManager) failed") end
        local pm = env[0].CallObjectMethod(env, activity, mGetPM)
        if not pm then error("getPackageManager() returned null") end
        logger.dbg("module_app_launcher: got PackageManager")

        -- Helper: check + clear any pending Java exception, return msg or nil
        local function jniCheckExc(label_)
            if env[0].ExceptionCheck(env) ~= 0 then
                env[0].ExceptionClear(env)
                return (label_ or "JNI") .. " threw a Java exception"
            end
            return nil
        end

        local IntentClass = env[0].FindClass(env, "android/content/Intent")
        if not IntentClass then error("FindClass(Intent) failed") end
        local mNewIntent = env[0].GetMethodID(
            env, IntentClass, "<init>", "(Ljava/lang/String;)V")
        if not mNewIntent then error("GetMethodID(Intent.<init>) failed") end

        local launchIntent

        if action then
            -- Action-based intent (e.g. android.settings.SETTINGS)
            logger.dbg("module_app_launcher: using action " .. action)
            local jAction = env[0].NewStringUTF(env, action)
            local argsA = ffi.new("union jvalue_u[1]")
            argsA[0].l = jAction
            launchIntent = env[0].NewObjectA(env, IntentClass, mNewIntent, ffi.cast("void*", argsA))
            env[0].DeleteLocalRef(env, jAction)
            local exc = jniCheckExc("new Intent(action)")
            if exc then error(exc) end
            if not launchIntent then error("new Intent(" .. action .. ") returned null") end
        else
            -- getLaunchIntentForPackage first
            local PMClass = env[0].GetObjectClass(env, pm)
            local mGetLaunch = env[0].GetMethodID(
                env, PMClass,
                "getLaunchIntentForPackage",
                "(Ljava/lang/String;)Landroid/content/Intent;")
            if not mGetLaunch then
                error("GetMethodID(getLaunchIntentForPackage) failed")
            end

            local jPkg = env[0].NewStringUTF(env, pkg)
            local args1 = ffi.new("union jvalue_u[1]")
            args1[0].l = jPkg
            launchIntent = env[0].CallObjectMethodA(env, pm, mGetLaunch, ffi.cast("void*", args1))
            env[0].DeleteLocalRef(env, jPkg)
            jniCheckExc("getLaunchIntentForPackage")  -- clear exc even if null

            if not launchIntent then
                -- Fallback: ACTION_MAIN + CATEGORY_LAUNCHER + setPackage
                logger.dbg("module_app_launcher: getLaunchIntentForPackage null, trying ACTION_MAIN fallback")
                local jAction2 = env[0].NewStringUTF(env, "android.intent.action.MAIN")
                local argsB = ffi.new("union jvalue_u[1]")
                argsB[0].l = jAction2
                launchIntent = env[0].NewObjectA(env, IntentClass, mNewIntent, ffi.cast("void*", argsB))
                env[0].DeleteLocalRef(env, jAction2)
                local exc2 = jniCheckExc("new Intent(ACTION_MAIN)")
                if exc2 then error(exc2) end
                if not launchIntent then error("new Intent(ACTION_MAIN) failed") end

                -- addCategory(LAUNCHER)
                local mAddCat = env[0].GetMethodID(
                    env, IntentClass,
                    "addCategory", "(Ljava/lang/String;)Landroid/content/Intent;")
                if mAddCat then
                    local jCat = env[0].NewStringUTF(env, "android.intent.category.LAUNCHER")
                    local argsCat = ffi.new("union jvalue_u[1]")
                    argsCat[0].l = jCat
                    env[0].CallObjectMethodA(env, launchIntent, mAddCat, ffi.cast("void*", argsCat))
                    env[0].DeleteLocalRef(env, jCat)
                    jniCheckExc("addCategory")
                end

                -- setPackage(pkg)
                local mSetPkg = env[0].GetMethodID(
                    env, IntentClass,
                    "setPackage", "(Ljava/lang/String;)Landroid/content/Intent;")
                if mSetPkg then
                    local jPkg2 = env[0].NewStringUTF(env, pkg)
                    local argsPkg = ffi.new("union jvalue_u[1]")
                    argsPkg[0].l = jPkg2
                    env[0].CallObjectMethodA(env, launchIntent, mSetPkg, ffi.cast("void*", argsPkg))
                    env[0].DeleteLocalRef(env, jPkg2)
                    jniCheckExc("setPackage")
                end
            end
        end
        logger.dbg("module_app_launcher: got launchIntent")

        -- intent.addFlags(FLAG_ACTIVITY_NEW_TASK)
        local IntentClass2 = env[0].GetObjectClass(env, launchIntent)
        local mAddFlags = env[0].GetMethodID(
            env, IntentClass2, "addFlags", "(I)Landroid/content/Intent;")
        if mAddFlags then
            local args2 = ffi.new("union jvalue_u[1]")
            args2[0].i = 0x10000000  -- FLAG_ACTIVITY_NEW_TASK
            env[0].CallObjectMethodA(env, launchIntent, mAddFlags, ffi.cast("void*", args2))
            jniCheckExc("addFlags")
            logger.dbg("module_app_launcher: added FLAG_ACTIVITY_NEW_TASK")
        end

        -- startActivity(intent)
        local mStart = env[0].GetMethodID(
            env, ActivityClass,
            "startActivity", "(Landroid/content/Intent;)V")
        if not mStart then error("GetMethodID(startActivity) failed") end
        local args3 = ffi.new("union jvalue_u[1]")
        args3[0].l = launchIntent
        env[0].CallVoidMethodA(env, activity, mStart, ffi.cast("void*", args3))
        local exc_start = jniCheckExc("startActivity")
        if exc_start then error(exc_start) end
        logger.dbg("module_app_launcher: startActivity called")

        env[0].DeleteLocalRef(env, launchIntent)    end)

    if ok_jni then
        logger.dbg("module_app_launcher: JNI launch succeeded for " .. pkg)
        return
    end
    logger.warn("module_app_launcher: JNI launch failed for " .. pkg .. ": " .. tostring(jni_err))

    -- ------------------------------------------------------------------ --
    -- Strategy 2: android.dictLookup "send" fallback                      --
    -- ------------------------------------------------------------------ --
    local ok_a2, android_mod2 = pcall(require, "android")
    if ok_a2 and android_mod2 and type(android_mod2.dictLookup) == "function" then
        local ok2, err2 = pcall(android_mod2.dictLookup, "", pkg, "send")
        if ok2 then
            logger.dbg("module_app_launcher: dictLookup send for " .. pkg)
            return
        end
        logger.warn("module_app_launcher: dictLookup failed: " .. tostring(err2))
    end

    logger.warn("module_app_launcher: all launch strategies failed for " .. pkg)
end

-- ---------------------------------------------------------------------------
-- Widget builder
-- ---------------------------------------------------------------------------

local function _buildWidget(w, d)
    local n = #APPS
    if n == 0 then return nil end

    local inner_w = w - PAD * 2
    local gap = n <= 1 and 0
        or math.max(0, math.floor((inner_w - n * d.frame_sz) / (n - 1)))

    local row = HorizontalGroup:new{ align = "top" }

    for i, app in ipairs(APPS) do
        -- Try to get a real app icon; fall back to abbreviation text
        local icon_path = _getIconPath(app.package, d.icon_sz)

        local inner_widget
        if icon_path then
            inner_widget = CenterContainer:new{
                dimen = Geom:new{ w = d.icon_sz, h = d.icon_sz },
                ImageWidget:new{
                    file   = icon_path,
                    width  = d.icon_sz,
                    height = d.icon_sz,
                    scale_factor = 0,  -- no auto-scale; we already sized the bitmap
                },
            }
        else
            inner_widget = CenterContainer:new{
                dimen = Geom:new{ w = d.icon_sz, h = d.icon_sz },
                TextWidget:new{
                    text    = app.abbr,
                    face    = Font:getFace("cfont", d.abbr_fs),
                    fgcolor = _CLR_TEXT,
                    padding = 0,
                },
            }
        end

        local icon_frame = FrameContainer:new{
            bordersize = 0,
            background = icon_path and nil or _CLR_FRAME_BG,
            radius     = d.corner_r,
            padding    = icon_path and 0 or d.frame_pad,
            inner_widget,
        }

        -- Label below icon
        local col = VerticalGroup:new{ align = "center" }
        col[#col + 1] = icon_frame
        col[#col + 1] = VerticalSpan:new{ width = d.lbl_sp }
        col[#col + 1] = CenterContainer:new{
            dimen = Geom:new{ w = d.frame_sz, h = d.lbl_h },
            TextWidget:new{
                text    = app.label,
                face    = Font:getFace("cfont", d.lbl_fs),
                fgcolor = _CLR_TEXT,
                width   = d.frame_sz,
            },
        }

        -- Tappable wrapper
        local col_h    = d.frame_sz + d.lbl_sp + d.lbl_h
        local _pkg     = app.package
        local _label   = app.label
        local _action  = app.action
        local tappable = InputContainer:new{
            dimen = Geom:new{ w = d.frame_sz, h = col_h },
            [1]   = col,
        }
        tappable.ges_events = {
            TapApp = {
                GestureRange:new{
                    ges   = "tap",
                    range = function() return tappable.dimen end,
                },
            },
        }
        function tappable:onTapApp()
            _launchApp(_pkg, _label, _action)
            return true
        end

        if i > 1 then
            row[#row + 1] = HorizontalSpan:new{ width = gap }
        end
        row[#row + 1] = tappable
    end

    return FrameContainer:new{
        bordersize   = 0,
        padding      = 0,
        padding_left = PAD,
        row,
    }
end

-- ---------------------------------------------------------------------------
-- Module descriptor
-- ---------------------------------------------------------------------------

local M = {}

M.id         = "app_launcher"
M.name       = "App Launcher"
M.label      = nil
M.default_on = false

function M.isEnabled(pfx)
    return G_reader_settings:readSetting(pfx .. "app_launcher_enabled") == true
end

function M.setEnabled(pfx, on)
    G_reader_settings:saveSetting(pfx .. "app_launcher_enabled", on)
end

function M.build(w, ctx)
    if not M.isEnabled(ctx.pfx) then return nil end
    local d = _getDims(Config.getModuleScale(M.id, ctx.pfx))
    return _buildWidget(w, d)
end

function M.getHeight(ctx)
    local d = _getDims(Config.getModuleScale(M.id, ctx.pfx))
    return d.frame_sz + d.lbl_sp + d.lbl_h
end

function M.getMenuItems(ctx_menu)
    local pfx     = ctx_menu.pfx
    local refresh = ctx_menu.refresh
    local _lc     = ctx_menu._ or function(s) return s end
    return {
        Config.makeScaleItem({
            text_func = function() return _lc("Scale") end,
            title     = _lc("Scale"),
            info      = _lc("Scale for this module.\n100% is the default size."),
            get       = function() return Config.getModuleScalePct(M.id, pfx) end,
            set       = function(v) Config.setModuleScale(v, M.id, pfx) end,
            refresh   = refresh,
        }),
    }
end

return M
