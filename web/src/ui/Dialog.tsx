/**
 * In-page confirmation for destructive actions, built on the native <dialog> element so focus
 * stays inside it, Escape cancels, and the page behind is inert. Never window.confirm.
 */
import { useEffect, useId, useRef, type ReactNode } from "react";

export interface ConfirmRequest {
  title: string;
  body: ReactNode;
  confirmLabel: string;
  /** Red button for things that delete or cut off; ember button otherwise. */
  destructive?: boolean;
  onConfirm: () => void | Promise<void>;
}

export function ConfirmDialog({ request, onClose }: { request: ConfirmRequest | null; onClose: () => void }) {
  const ref = useRef<HTMLDialogElement>(null);
  const titleId = useId();
  const bodyId = useId();

  useEffect(() => {
    const dialog = ref.current;
    if (!dialog) return;
    if (request && !dialog.open) dialog.showModal();
    if (!request && dialog.open) dialog.close();
  }, [request]);

  return (
    <dialog
      ref={ref}
      className="dialog"
      aria-labelledby={titleId}
      aria-describedby={bodyId}
      onClose={onClose}
      onClick={(event) => {
        // A click on the dimmed backdrop (the dialog element itself, outside the panel) cancels.
        if (event.target === ref.current) ref.current?.close();
      }}
    >
      {request && (
        <form
          method="dialog"
          className="dialog__panel"
          onSubmit={(event) => {
            event.preventDefault();
            void Promise.resolve(request.onConfirm()).finally(() => ref.current?.close());
          }}
        >
          <h2 id={titleId} className="dialog__title">{request.title}</h2>
          <div id={bodyId} className="dialog__body">{request.body}</div>
          <div className="dialog__actions">
            <button type="button" className="button button--quiet" onClick={() => ref.current?.close()} autoFocus>
              Cancel
            </button>
            <button type="submit" className={`button ${request.destructive ? "button--danger" : "button--primary"}`}>
              {request.confirmLabel}
            </button>
          </div>
        </form>
      )}
    </dialog>
  );
}
