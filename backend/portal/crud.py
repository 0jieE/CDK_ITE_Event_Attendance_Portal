"""A small, reusable HTMX-CRUD engine.

Each managed section (Events, Users, Students, …) is described by one
:class:`CrudSection` subclass.  The engine generates the list / create / update
/ delete views and the URL patterns, all following the same HTMX modal pattern:

* **List**  — full page normally; just the table fragment on an HTMX refresh.
* **Add/Edit** — ``hx-get`` returns a form partial into the modal; ``hx-post``
  saves and (on success) fires a toast + table-refresh event and closes the
  modal; on error the form re-renders with messages.
* **Delete** — ``hx-post`` deletes, then fires a toast + table-refresh event.

Only a per-section *table* partial differs between sections; the page shell and
the modal form template are shared.
"""

from django.shortcuts import get_object_or_404, render
from django.urls import path

from .mixins import admin_required, htmx_action_response, is_htmx


class CrudSection:
    """Declarative description of one CRUD-managed model."""

    #: URL slug and template namespace, e.g. ``"events"``.
    section = ""
    #: Human titles.
    title = ""          # plural, e.g. "Events"
    singular = ""       # e.g. "Event"

    model = None
    form_class = None

    #: Per-section table fragment; the rest of the chrome is shared.
    table_template = None  # e.g. "portal/events/partials/table.html"

    #: Optional default ordering / select_related for the list queryset.
    order_by = None
    select_related = ()

    can_add = True
    can_edit = True
    can_delete = True

    # -- queryset -----------------------------------------------------------
    def get_queryset(self):
        qs = self.model._default_manager.all()
        if self.select_related:
            qs = qs.select_related(*self.select_related)
        if self.order_by:
            qs = qs.order_by(*self.order_by)
        return qs

    def get_form(self, request, instance=None):
        if request.method == "POST":
            return self.form_class(request.POST, request.FILES, instance=instance)
        return self.form_class(None, instance=instance)

    # -- shared context -----------------------------------------------------
    @property
    def refresh_event(self):
        return f"refresh-{self.section}"

    def urlnames(self):
        s = self.section
        return {
            "list": f"{s}-list",
            "add": f"{s}-add",
            "edit": f"{s}-edit",
            "delete": f"{s}-delete",
        }

    def base_context(self, request):
        names = self.urlnames()
        from django.urls import reverse

        return {
            "active": self.section,
            "section": self.section,
            "title": self.title,
            "singular": self.singular,
            "table_template": self.table_template,
            "refresh_event": self.refresh_event,
            "list_url": reverse(f"portal:{names['list']}"),
            "add_url": reverse(f"portal:{names['add']}") if self.can_add else None,
            "edit_urlname": f"portal:{names['edit']}",
            "delete_urlname": f"portal:{names['delete']}",
            "can_edit": self.can_edit,
            "can_delete": self.can_delete,
        }

    # -- views --------------------------------------------------------------
    def list_view(self, request):
        ctx = self.base_context(request)
        ctx["objects"] = self.get_queryset()
        # HTMX refreshes ask only for the table fragment.
        if is_htmx(request) and request.GET.get("partial") == "table":
            return render(request, self.table_template, ctx)
        return render(request, "portal/partials/crud_page.html", ctx)

    def _render_form(self, request, form, *, form_title, post_url, status=200):
        ctx = {
            "form": form,
            "form_title": form_title,
            "post_url": post_url,
        }
        return render(request, "portal/partials/modal_form.html", ctx, status=status)

    def create_view(self, request):
        from django.urls import reverse

        post_url = reverse(f"portal:{self.urlnames()['add']}")
        title = f"Add {self.singular}"
        if request.method == "POST":
            form = self.get_form(request)
            if form.is_valid():
                form.save()
                return htmx_action_response(
                    toast=f"{self.singular} created.",
                    refresh_event=self.refresh_event,
                )
            return self._render_form(
                request, form, form_title=title, post_url=post_url, status=422
            )
        return self._render_form(
            request, self.form_class(), form_title=title, post_url=post_url
        )

    def update_view(self, request, pk):
        from django.urls import reverse

        instance = get_object_or_404(self.model, pk=pk)
        post_url = reverse(f"portal:{self.urlnames()['edit']}", args=[pk])
        title = f"Edit {self.singular}"
        if request.method == "POST":
            form = self.get_form(request, instance=instance)
            if form.is_valid():
                form.save()
                return htmx_action_response(
                    toast=f"{self.singular} updated.",
                    refresh_event=self.refresh_event,
                )
            return self._render_form(
                request, form, form_title=title, post_url=post_url, status=422
            )
        form = self.form_class(instance=instance)
        return self._render_form(
            request, form, form_title=title, post_url=post_url
        )

    def perform_delete(self, instance):
        """Delete hook — overridable (e.g. to also remove a linked user)."""
        instance.delete()

    def delete_view(self, request, pk):
        instance = get_object_or_404(self.model, pk=pk)
        label = str(instance)
        self.perform_delete(instance)
        return htmx_action_response(
            toast=f"{self.singular} deleted: {label}.",
            refresh_event=self.refresh_event,
            close_modal=False,
        )

    # -- url wiring ---------------------------------------------------------
    def get_urls(self):
        names = self.urlnames()
        s = self.section
        return [
            path(f"{s}/", admin_required(self.list_view), name=names["list"]),
            path(f"{s}/add/", admin_required(self.create_view), name=names["add"]),
            path(f"{s}/<int:pk>/edit/", admin_required(self.update_view), name=names["edit"]),
            path(f"{s}/<int:pk>/delete/", admin_required(self.delete_view), name=names["delete"]),
        ]
