#!/bin/sh
# Rewrites the stand-in for WD's /var/www/xml/apkg_all.xml from the apps in Nas_Prog
P="$(cat /etc/store_test_volume)/Nas_Prog"
{
	echo '<?xml version="1.0" encoding="UTF-8"?>'
	echo '<config><apkg>'
	for rc in "$P"/*/apkg.rc; do
		[ -f "$rc" ] || continue
		get() { sed -n "s/^$1:[[:space:]]*//p" "$rc"; }
		enable=1; [ -f "$(dirname "$rc")/.disabled" ] && enable=0
		# (as WD writes it: center_type before name)
		echo "<item><procudt_id>1</procudt_id><user_control>1</user_control><center_type>$(get CenterType)</center_type><name>$(get Package)</name><show>$(get AddonShowName)</show><enable>$enable</enable><version>$(get Version)</version><date>1</date><inst_date>10/23/2026 10:00:00</inst_date><url>$(get AddonIndexPage)</url><url_port></url_port><inst_depend>$(get InstDepend)</inst_depend><description>$(get Description)</description><icon>$(get Icon)</icon></item>"
	done
	echo '</apkg></config>'
} > /var/www/xml/apkg_all.xml
