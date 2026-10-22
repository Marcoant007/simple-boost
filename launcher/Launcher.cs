// Executável do BLK Boost: carrega o BlkBoost.ps1 embutido e abre a interface sem janela de console.
// O app.manifest faz o Windows pedir administrador ao abrir (o script precisa disso).
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Windows.Forms;

[assembly: AssemblyTitle("BLK Boost")]
[assembly: AssemblyDescription("Otimizador para jogos")]
[assembly: AssemblyProduct("BLK Boost")]
[assembly: AssemblyCompany("BLK")]
[assembly: AssemblyCopyright("BLK")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

static class Program
{
    [STAThread]
    static int Main()
    {
        try
        {
            string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "BlkBoost", "app");
            PrepareDir(dir);
            string script = Path.Combine(dir, "BlkBoost.ps1");
            Extract("BlkBoost.ps1", script);
            Extract("BlkBoost.ico", Path.Combine(dir, "BlkBoost.ico"));

            var psi = new ProcessStartInfo(
                Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"),
                "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            Process.Start(psi);
            return 0;
        }
        catch (Exception e)
        {
            MessageBox.Show("Não foi possível abrir o BLK Boost:\n\n" + e.Message, "BLK Boost",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    // O script roda como administrador, então a pasta dele só pode ser alterada por administradores
    static void PrepareDir(string dir)
    {
        Directory.CreateDirectory(dir);
        var sec = new DirectorySecurity();
        sec.SetAccessRuleProtection(true, false);
        const InheritanceFlags inherit = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
        sec.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            FileSystemRights.FullControl, inherit, PropagationFlags.None, AccessControlType.Allow));
        sec.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null),
            FileSystemRights.FullControl, inherit, PropagationFlags.None, AccessControlType.Allow));
        sec.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null),
            FileSystemRights.ReadAndExecute, inherit, PropagationFlags.None, AccessControlType.Allow));
        Directory.SetAccessControl(dir, sec);
    }

    static void Extract(string name, string path)
    {
        using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
        using (FileStream f = File.Create(path))
        {
            s.CopyTo(f);
        }
    }
}
