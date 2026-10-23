<?php
$date = new DateTime();
$r = $date->getTimestamp();
?>
<!doctype html>
<html>
<!--
SPDX-FileCopyrightText: 2020 Western Digital Corporation or its affiliates.

SPDX-License-Identifier: GPL-2.0-or-later

The dashboard's Apps page, replaced by the Store app (bind-mounted over WD's addons/app.php while the Store is on, so
WD's own comes back when it's off or removed). Instead of the list of installed apps down the side, it shows the Store,
full width: its Installed tab opens each app's page (Configure), and its WD Store tab is WD's own app store and manual
install - WD's scripts and dialogs below, unchanged.
-->
<head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<meta http-equiv="PRAGMA" content="no-cache">
<meta http-equiv="Expires" content="-1">
<meta http-equiv="Cache-Control" content="no-cache">
<style>
#AppsDiag_Manually_Install{
	color: #15ABFF;
	font-size: 14px;
}
#TR_AppsDiag_Browse_Manually_Install .file_input_div{
	cursor: pointer;
	position: relative;
	width:auto;
	height:auto;
}

#TR_AppsDiag_Browse_Manually_Install .file_input_hidden
{
	cursor: pointer;
	font-size: 50px;
	position: absolute;
	right: 0px;
	top: 0px;
	opacity: 0;
	filter: alpha(opacity=0);
	-ms-filter: "alpha(opacity=0)";
	-khtml-opacity: 0;
	-moz-opacity: 0;
}

/* [+] For Apps Install bar */
#Apps_InstallApps_parogressbar .ui-widget-header {
	background: #15ABFF;
}

#Apps_InstallApps_parogressbar .ui-widget-content {
    background: #15ABFF;
}
#Apps_InstallApps_parogressbar{
    border: 0;
    background-color: #DCDCDC;
}
.ui-progressbar .ui-progressbar-value {
	border: 0;
    border-radius: 0 !important;
    margin: 0;
}
/* [-] For Apps Install bar */
#AppsEulaText{
	background-color:#fff;
}
#AppsEula_iframe{
	width:100%;
	height:100%;
	border:none;
}

#AppsDiag_Browse_List .LightningCheckbox span{
	left: 5px;
}

#Apps_Diag .grayout{
	filter:alpha(opacity=30);opacity:0.3; top:15px;left:0;cursor: text;
}

/* The Store's layout: the page (the Store, or an app's page opened by Configure) uses the full width */
#store-apps-page { position: relative; }
/* Apps' own pages (Configure), as their shared styles now are - here too for apps built before: the full width, and their
   links that act as buttons (e.g. "Open Grafana") in WD's blue */
#store-apps-page #mainbody > div { max-width: none !important; }
#store-apps-page #mainbody a.mg-button { text-decoration: none; color: #fafafa; border-top: 1px solid #15abff; border-bottom: 1px solid #0067a6; outline: 1px solid #0067a6; background-color: #018be3; background-image: linear-gradient(to bottom, #0099ff, #027dc8); background-origin: border-box; background-repeat: no-repeat; box-sizing: border-box; height: 32px; padding-top: 0; padding-bottom: 0; font: 14px Arial, "Helvetica Neue", Helvetica, sans-serif; line-height: 30px; }
#store-apps-page #mainbody a.mg-button:hover { background-image: linear-gradient(to bottom, #027dc8, #0099ff); }
#store-apps-page #mainbody { width: auto; max-width: none; float: none; margin: 0; }
/* An app's page gets a Back button (as the Store's own pages have) at the right of its title - or, without a title, at the
   top right */
.store-apps-back { float: right; margin: 0 0 0 1rem; height: auto; line-height: 1.4; padding: 0.3rem 0.9rem; font-weight: normal; }
#store-apps-page > .store-apps-back { position: absolute; top: 0; right: 0; float: none; }
#store-wd-parts { display: none; }
#store-wd-manual #manually_install_td { padding: 0.25rem 0 0.75rem; }
</style>
</head>

<script type="text/javascript" src="/web/function/app_menu.js?v=<?=$r;?>"></script>
<script type="text/javascript" src="/web/function/appsDiag.js?v=<?=$r;?>"></script>

<script type="text/javascript">
var APPS_EULA = 0;

// For the Store's page: opening an app's own page (Configure) and back, and WD's app store in its WD Store tab
window.storeApps = {
	// The Store, in the page's main area (its page reopens what was open before Configure - it keeps that itself)
	home: function () {
		storeApps.leave();
		storeApps.back = false;
		go_sub_page('/apps/store/index.php', 'store');
		// (if the Store's page can't be shown, this is still the way back to WD's own Apps page)
		setTimeout(function () {
			if (!$("#store-manage").length && !storeApps.back) {
				$("#mainbody").html('<p>The Store\'s page could not be loaded. To get the NAS\'s own Apps page back, run this over SSH:</p>'
					+ '<pre>umount /usr/local/modules/web/pages/addons/app.php</pre><p>(or reinstall the Store app).</p>');
			}
		}, 10000);
	},
	// An app's own page (its CenterType 1 index page), with a way back to the Store (see loaded). Its name is on its page
	configure: function (id, url, name) {
		storeApps.leave();
		storeApps.back = true;
		go_sub_page('/apps/' + id + '/' + url, id);
	},
	// A page has been loaded into the main area: an app's gets its Back button, in its title's row (its first heading)
	loaded: function () {
		$("#store-apps-page .store-apps-back").remove();
		if (!storeApps.back) {
			return;
		}
		var back = $('<button type="button" class="store-apps-back">&larr; Back</button>').on("click", storeApps.home);
		var title = $("#mainbody").find("h1, h2, .header_1").first();
		if (title.length) {
			title.prepend(back);
		} else {
			$("#store-apps-page").prepend(back);
		}
	},
	back: false,
	// Before the main area is replaced: WD's app store goes back to its hiding place (else it's lost with the page), and
	// is loaded again next time (WD's page loader unbinds every handler in the page)
	leave: function () {
		$("#store-wd-parts").append($("#store-wd-store"), $("#store-wd-manual"));
		storeApps.wdLoaded = false;
	},
	// WD's manual install (an app's .bin from this computer), moved into the Store's tab: as WD's Apps page did, the
	// NAS's EULA is checked first, then the link becomes a file chooser that uploads to WD's installer
	wdManual: function (holder) {
		$(holder).append($("#store-wd-manual"));
		apps_eula();
		language();
	},
	// WD's app store, moved into the Store's tab (and loaded as WD's Apps page did, the first time)
	wdStore: function (holder) {
		$(holder).append($("#store-wd-store"));
		if (storeApps.wdLoaded) {
			return;
		}
		storeApps.wdLoaded = true;
		$("#available_apps").html('<div class="SpinnerSun"><span>' + _T('_common','loading') + '</span></div>');
		HD_Status(0, function (hd_status) {
			apps_eula();
			load_app_info(function () {
				load_app_info_json(function () {
					load_app_menu();
					load_available_apps();
					language();
				});
			});
		});
	},
	wdLoaded: false
};

function page_load(_sub_page, _sub_page_callback)
{
	// (pages shown in the main area afterwards - the Store's, apps' - get this as their page_load, as WD's own app store
	// page gives them: without it, each would reload this page)
	window.page_load = function (callback) {
		storeApps.loaded();
		if (typeof(callback) == "function") callback();
	};
	window.page_unload = function () {};
	get_ip_address();
	storeApps.home();
}
function page_unload()
{
}
</script>

<body>
<div id="store-apps-page">
	<div class="r_content mainbody" id="mainbody"></div>
</div>

<!-- WD's parts that its scripts need: its manual install and its app store (moved into the Store's Manual install and
     WD Store tabs), and the list of installed apps it fills in (not shown: the Store's Installed tab lists them) -->
<div id="store-wd-parts">
	<div id="store-wd-manual">
		<form method="post" id="app_manually_install_form" enctype="multipart/form-data" action="/cgi-bin/apkg_mgr.cgi">
			<input type="hidden" name="cmd" value="cgi_apps_install">
			<table>
				<tr>
					<td id="TR_AppsDiag_Browse_Manually_Install">
						<table border="0" width="100%" style="border-collapse: separate; border-spacing: 5px;position: relative; left: -8px;">
							<tr>
								<td id="manually_install_td"></td>
							</tr>
						</table>
					</td>
				</tr>
			</table>
		</form>
	</div>
	<div id="store-wd-store">
		<table cellspacing="0" cellpadding="0" border="0" style="width: 100%;">
			<tr valign="bottom">
				<td align="left"><div id="apps_msg" class="_text" lang="_module" datafld="desc32" style="display:none"></div></td>
				<td align="right"><div id="div_apps_upgrade"></div></td>
			</tr>
		</table>
		<div id="available_apps"></div>
	</div>
	<div id="app_store"></div>
	<div id="SubMenuDiv" class="appsDiv">
		<div class="LightningSubMenubg">
			<ul class="LightningSubMenu">
			</ul>
		</div>
	</div>
</div>

<div id="moreDiag" class="WDLabelDiag" style="display:none">
	<div class="WDLabelHeaderDialogue" id="appName_title"></div>
	<div align="center"><div class="hr"><hr/></div></div>
	<div class="WDLabelBodyDialogue">
		<div id="appDesc_div"></div>
	</div>
	<div class="hrBottom2"><hr/></div>
	<button type="button" class="ButtonRightPos2 close"><span class="_text" lang="_button" datafld="close"></span></button>
</div>

<?php include("./appsDiag.html"); ?>

</body>
</html>
