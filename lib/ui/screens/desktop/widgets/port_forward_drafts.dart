import 'package:zestssh/features/orchards/move/item_transfer.dart'
    show SavePlace;
import 'package:zestssh/ui/screens/desktop/widgets/port_forward_edit_controller.dart';
import 'package:zestssh/ui/widgets/edit_drafts.dart';

/// The key a new rule's form is kept under (a saved rule's is its id).
const String kPfNewRuleDraftKey = '__new__';

/// One editor's unsaved state, with where a new rule was to be saved.
typedef PfKeptEdit = ({PfEditDraft edit, SavePlace? saveIn});

/// The Port Forwarding editor's unsaved edits while its page is away
/// ([EditDrafts]): kept by the rule's id, or [kPfNewRuleDraftKey] for a new
/// rule's form, and put back as unsaved when the page comes back. Save,
/// Cancel, Discard and deleting the rule leave nothing here.
typedef PortForwardDrafts = EditDrafts<PfKeptEdit>;

/// The Port Forwarding editor's drafts ([PortForwardDrafts]).
final portForwardDraftsProvider = editDraftsProvider<PfKeptEdit>();
