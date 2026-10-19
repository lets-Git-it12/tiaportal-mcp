using System.Collections.Generic;

namespace TiaMcpServer.ModelContextProtocol
{
    public class ResponseHmiDynamizations : ResponseMessage
    {
        /// <summary>Items that have at least one (matching) dynamization.</summary>
        public IEnumerable<TiaMcpServer.Siemens.HmiItemDynamizations>? Items { get; set; }

        /// <summary>Set when the call stopped early; the list is then incomplete.</summary>
        public string? StoppedReason { get; set; }
    }

    /// <summary>Result of a dynamization write: the dynamization as read back, and what it replaced.</summary>
    public class ResponseHmiDynamizationWrite : ResponseMessage
    {
        public string? ItemName { get; set; }

        /// <summary>The dynamization as read back after the change; null after a delete.</summary>
        public TiaMcpServer.Siemens.HmiDynamizationDetail? Dynamization { get; set; }

        /// <summary>The dynamization before the change; null when the property was not dynamized.</summary>
        public TiaMcpServer.Siemens.HmiDynamizationDetail? Previous { get; set; }

        /// <summary>JSON file holding 'Previous', written before the change.</summary>
        public string? Backup { get; set; }

        public string? BackupWarning { get; set; }
    }
}
