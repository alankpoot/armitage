package ui;

import java.awt.*;
import java.awt.event.*;

import javax.swing.*;
import java.util.*;

/* Spawn common dialogs in their own thread (so they don't block Sleep interpreter)
   and report their results to a callback function */
public class SafeDialogs {
	/* our callback interface... will always return a string I guess */
	public interface SafeDialogCallback {
		public void result(String r);
	}

	/* prompts the user with a yes/no question. Does not call callback unless the user presses
	   yes. askYesNo is always a confirm action anyways */
	public static void askYesNo(final String text, final String title, final SafeDialogCallback callback) {
		new Thread(new Runnable() {
			public void run() {
				int result = JOptionPane.showConfirmDialog(null, text, title, JOptionPane.YES_NO_OPTION);
				if (result == JOptionPane.YES_OPTION || result == JOptionPane.OK_OPTION) {
					callback.result("yes");
				}
			}
		}).start();
	}
}