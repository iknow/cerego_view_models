require "cerego_view_models/version"
require "view_model"
require "active_record_view_model"
require "active_record_view_model/controller"

module CeregoViewModels

  class ExceptionView < ViewModel
    attributes :exception, :status
    def serialize_view(json, view_context: default_serialize_context)
      json.errors [exception] do |e|
        json.status status
        json.detail exception.message
        if Rails.env != 'production'
          json.set! :class, exception.class.name
          json.backtrace exception.backtrace
        end
      end
    end
  end


  # expects a class that defines a "render" method
  # accepting json as a key like ActionController::Base
  # defines klass#render_view_model on the class

  def self.renderable!(klass)
    klass.class_eval do
      def render_viewmodel(viewmodel, status: nil, view_context: viewmodel.default_deserialize_context)
        render_jbuilder(status: status) do |json|
          json.data do
            ViewModel.serialize(viewmodel, json, view_context: view_context)
          end

          if view_context.has_references?
            json.references do
              view_context.serialize_references(json)
            end
          end
        end
      end

      def render_error(exception, status = 500)
        render_jbuilder(status: status) do |json|
          ViewModel.serialize(ExceptionView.new(exception, status), json)
        end
      end

      private

      def render_jbuilder(status:)
        response = Jbuilder.encode do |json|
          yield json
        end

        ## jbuilder prevents this from working
        ##  - https://github.com/rails/jbuilder/issues/317
        ##  - https://github.com/rails/rails/issues/23923

        # render(json: response, status: status)

        render(plain: response, status: status, content_type: 'application/json')
      end
    end
  end
end
